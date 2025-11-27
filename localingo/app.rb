require 'sinatra'
require 'json'
require 'net/http'
require 'uri'
require 'logger'
require 'fileutils'

set :port, 4567
set :bind, '0.0.0.0'

# ロガーの設定
logger = Logger.new(STDOUT)
logger.level = Logger::INFO
STDOUT.sync = true

set :public_folder, 'public'

# 環境変数から設定を読み込む
LLM_ENDPOINT = ENV['LLM_ENDPOINT'] || 'http://host.docker.internal:1234'
PDF_TRANSLATE_ENDPOINT = ENV['PDF_TRANSLATE_ENDPOINT'] || 'http://pdf2zh:11007'
TRANSLATIONS_FILE = 'data/translations.json'
PDF_DIR = 'data/pdfs'
SAVE_TRANSLATIONS = ENV['SAVE_TRANSLATIONS'] != 'false'

# PDF翻訳タスクのメタデータを一時保存するハッシュ
PDF_TASK_METADATA = {}

# ディレクトリ作成
FileUtils.mkdir_p(File.dirname(TRANSLATIONS_FILE))
FileUtils.mkdir_p(PDF_DIR)

# 言語マッピング
LANGUAGE_MAP = {
  'ja' => 'Japanese',
  'ja-easy' => 'Japanese(easy)',
  'en' => 'English',
  'zh' => 'Chinese',
  'zh-tw' => 'Taiwanese',
  'ko' => 'Korean',
  'ar' => 'Arabic',
  'it' => 'Italian',
  'id' => 'Indonesian',
  'nl' => 'Dutch',
  'es' => 'Spanish',
  'th' => 'Thai',
  'de' => 'German',
  'fr' => 'French',
  'vi' => 'Vietnamese',
  'ru' => 'Russian',
  'auto' => 'English|Japanese'
}

# 翻訳履歴を読み込む
def load_translations
  if File.exist?(TRANSLATIONS_FILE)
    content = File.read(TRANSLATIONS_FILE)
    JSON.parse(content) rescue []
  else
    []
  end
end

# テキスト翻訳結果をJSONファイルに保存する
def save_text_translation(input_text, output_text, source_lang, target_lang, metrics)
  translations = load_translations
  
  translation_record = {
    type: 'text',
    timestamp: Time.now.iso8601,
    source_lang: source_lang,
    target_lang: target_lang,
    input: input_text,
    output: output_text,
    metrics: metrics
  }

  translations << translation_record
  File.write(TRANSLATIONS_FILE, JSON.pretty_generate(translations))
  logger.info "Text translation saved to #{TRANSLATIONS_FILE}"
rescue => e
  logger.error "Failed to save text translation: #{e.message}"
end

# PDF翻訳結果をJSONファイルに保存する
def save_pdf_translation(task_id, filename, source_lang, target_lang, pages, metrics)
  translations = load_translations
  
  translation_record = {
    type: 'pdf',
    timestamp: Time.now.iso8601,
    task_id: task_id,
    filename: filename,
    source_lang: source_lang,
    target_lang: target_lang,
    pages: pages,
    metrics: metrics
  }

  translations << translation_record
  File.write(TRANSLATIONS_FILE, JSON.pretty_generate(translations))
  logger.info "PDF translation saved to #{TRANSLATIONS_FILE}"
rescue => e
  logger.error "Failed to save PDF translation: #{e.message}"
end

# トップページの表示
get '/' do
  send_file File.join(settings.public_folder, 'index.html')
end

# テキスト翻訳APIエンドポイント(Server-Sent Events形式でストリーミング)
post '/api/translate-text' do
  content_type 'text/event-stream'
  
  stream :keep_open do |out|
    begin
      request_body = JSON.parse(request.body.read)
      text = request_body['text']
      source_lang = request_body['source_lang'] || 'auto'
      target_lang = request_body['target_lang'] || 'auto'

      logger.info "=== Text Translation Request ==="
      logger.info "Source: #{source_lang} (#{LANGUAGE_MAP[source_lang]})"
      logger.info "Target: #{target_lang} (#{LANGUAGE_MAP[target_lang]})"
      logger.info "Text length: #{text&.length || 0}"

      input_lang = LANGUAGE_MAP[source_lang] || LANGUAGE_MAP['auto']
      output_lang = LANGUAGE_MAP[target_lang] || LANGUAGE_MAP['auto']
      
      prompt = "<|plamo:op|>dataset\ntranslation\n\n<|plamo:op|>input lang=#{input_lang}\n#{text}<|plamo:op|>output lang=#{output_lang}"

      uri = URI.parse("#{LLM_ENDPOINT}/v1/chat/completions")

      token_count = 0
      accumulated_output = ""
      start_time = Time.now
      first_token_time = nil
      translation_saved = false
      
      Net::HTTP.start(uri.host, uri.port, read_timeout: 300) do |http|
        request = Net::HTTP::Post.new(uri.path)
        request['Content-Type'] = 'application/json'
        request.body = {
          model: 'plamo-2-translate',
          messages: [{ role: 'user', content: prompt }],
          stop: ["<|plamo:op|>", "<|plamo:reserved:0x1E|>"],
          stream: true
        }.to_json

        http.request(request) do |response|
          unless response.code == '200'
            logger.error "HTTP Error: #{response.code}"
            out << "data: #{JSON.generate({ error: "HTTP #{response.code}: #{response.message}" })}\n\n"
            next
          end

          buffer = ''
          
          response.read_body do |chunk|
            buffer += chunk
            lines = buffer.split("\n", -1)
            buffer = lines.pop || ''
            
            lines.each do |line|
              line = line.strip
              next if line.empty?
              next unless line.start_with?('data: ')

              data = line.sub('data: ', '').strip

              if data == '[DONE]'
                end_time = Time.now
                total_time = end_time - start_time
                time_to_first_token = first_token_time ? first_token_time - start_time : 0
                tokens_per_sec = token_count > 0 ? token_count / total_time : 0
                
                if SAVE_TRANSLATIONS && !translation_saved && accumulated_output != ""
                  metrics = {
                    token_count: token_count,
                    time_to_first_token: time_to_first_token.round(3),
                    total_time: total_time.round(3),
                    tokens_per_sec: tokens_per_sec.round(2)
                  }
                  save_text_translation(text, accumulated_output, source_lang, target_lang, metrics)
                  translation_saved = true
                end
                
                out << "data: #{JSON.generate({ done: true })}\n\n"
                next
              end

              begin
                json = JSON.parse(data)
                content = json.dig('choices', 0, 'delta', 'content')
                
                if content
                  token_count += 1
                  first_token_time ||= Time.now
                  accumulated_output += content
                  out << "data: #{JSON.generate({ token: content })}\n\n"
                end

                finish_reason = json.dig('choices', 0, 'finish_reason')
                if finish_reason == 'stop'
                  end_time = Time.now
                  total_time = end_time - start_time
                  time_to_first_token = first_token_time ? first_token_time - start_time : 0
                  tokens_per_sec = token_count > 0 ? token_count / total_time : 0
                  
                  if SAVE_TRANSLATIONS && !translation_saved && accumulated_output != ""
                    metrics = {
                      token_count: token_count,
                      time_to_first_token: time_to_first_token.round(3),
                      total_time: total_time.round(3),
                      tokens_per_sec: tokens_per_sec.round(2)
                    }
                    save_text_translation(text, accumulated_output, source_lang, target_lang, metrics)
                    translation_saved = true
                  end
                  
                  out << "data: #{JSON.generate({ done: true })}\n\n"
                  next
                end
              rescue JSON::ParserError => e
                logger.error "JSON parse error: #{e.message}"
              end
            end
          end
          
          unless buffer.empty?
            if buffer.start_with?('data: ')
              data = buffer.sub('data: ', '').strip
              if data == '[DONE]'
                end_time = Time.now
                total_time = end_time - start_time
                time_to_first_token = first_token_time ? first_token_time - start_time : 0
                tokens_per_sec = token_count > 0 ? token_count / total_time : 0
                
                if SAVE_TRANSLATIONS && !translation_saved && accumulated_output != ""
                  metrics = {
                    token_count: token_count,
                    time_to_first_token: time_to_first_token.round(3),
                    total_time: total_time.round(3),
                    tokens_per_sec: tokens_per_sec.round(2)
                  }
                  save_text_translation(text, accumulated_output, source_lang, target_lang, metrics)
                  translation_saved = true
                end
                
                out << "data: #{JSON.generate({ done: true })}\n\n"
              end
            end
          end
        end
      end

    rescue Errno::ECONNREFUSED => e
      logger.error "Cannot connect to LLM endpoint: #{LLM_ENDPOINT}"
      out << "data: #{JSON.generate({ error: "LLMサーバーに接続できません" })}\n\n"
    rescue StandardError => e
      logger.error "Error: #{e.class} - #{e.message}"
      out << "data: #{JSON.generate({ error: e.message })}\n\n"
    ensure
      out.close
    end
  end
end

# PDF翻訳開始（タスクIDを即座に返す）
post '/api/translate-pdf' do
  content_type :json
  
  begin
    pdf_file = params['file']
    source_lang = params['source_lang'] || 'en'
    target_lang = params['target_lang'] || 'ja'
    pages = params['pages']

    unless pdf_file && pdf_file[:tempfile]
      status 400
      return { error: "PDFファイルがアップロードされていません" }.to_json
    end

    original_filename = pdf_file[:filename]
    logger.info "=== PDF Translation Request ==="
    logger.info "File: #{original_filename}"
    logger.info "Source: #{source_lang}(#{LANGUAGE_MAP[source_lang]})"
    logger.info "Target: #{target_lang}(#{LANGUAGE_MAP[target_lang]})"

    lang_in = LANGUAGE_MAP[source_lang] || 'English'
    lang_out = LANGUAGE_MAP[target_lang] || 'Japanese'

    prompt = "<|plamo:op|>dataset\ntranslation\n<|plamo:op|>input lang=${lang_in}\n${text}\n<|plamo:op|>output lang=${lang_out}"

    uri = URI.parse("#{PDF_TRANSLATE_ENDPOINT}/v1/translate")
    boundary = "----WebKitFormBoundary#{rand(1000000000)}"
    
    data_payload = {
      lang_in: lang_in,
      lang_out: lang_out,
      service: "openailiked",
      thread: 10,
      prompt: prompt
    }
    
    if pages && !pages.empty?
      data_payload[:pages] = pages.is_a?(String) ? JSON.parse(pages) : pages
    end

    post_body = []
    post_body << "--#{boundary}\r\n"
    post_body << "Content-Disposition: form-data; name=\"file\"; filename=\"#{original_filename}\"\r\n"
    post_body << "Content-Type: application/pdf\r\n\r\n"
    post_body << pdf_file[:tempfile].read
    post_body << "\r\n"
    post_body << "--#{boundary}\r\n"
    post_body << "Content-Disposition: form-data; name=\"data\"\r\n\r\n"
    post_body << data_payload.to_json
    post_body << "\r\n"
    post_body << "--#{boundary}--\r\n"
    
    body = post_body.join

    http = Net::HTTP.new(uri.host, uri.port)
    http.read_timeout = 10
    
    request = Net::HTTP::Post.new(uri.path)
    request['Content-Type'] = "multipart/form-data; boundary=#{boundary}"
    request.body = body

    logger.info "Submitting PDF translation task..."
    response = http.request(request)
    
    unless response.code == '200'
      logger.error "Failed to submit task: #{response.code}"
      status 500
      return { error: "翻訳タスクの送信に失敗しました: #{response.message}" }.to_json
    end

    task_response = JSON.parse(response.body)
    task_id = task_response['id']
    
    unless task_id
      logger.error "No task ID returned"
      status 500
      return { error: "タスクIDが取得できませんでした" }.to_json
    end

    logger.info "Task submitted: #{task_id}"

    # 元のPDFを保存
    timestamp = Time.now.strftime('%Y%m%d_%H%M%S')
    saved_filename = "#{timestamp}_#{task_id}_original.pdf"
    saved_path = File.join(PDF_DIR, saved_filename)
    
    pdf_file[:tempfile].rewind
    File.open(saved_path, 'wb') { |f| f.write(pdf_file[:tempfile].read) }
    logger.info "Original PDF saved: #{saved_path}"

    # タスク情報を一時保存（完了後の記録用）
    PDF_TASK_METADATA[task_id] = {
      filename: original_filename,
      source_lang: source_lang,
      target_lang: target_lang,
      pages: pages,
      start_time: Time.now
    }

    # タスクIDを返す
    { task_id: task_id }.to_json

  rescue StandardError => e
    logger.error "Error: #{e.class} - #{e.message}"
    status 500
    { error: e.message }.to_json
  end
end

# PDF翻訳ステータス取得（ブラウザがポーリング）
get '/api/translate-pdf/:task_id/status' do
  content_type :json
  
  task_id = params['task_id']
  
  begin
    uri = URI.parse("#{PDF_TRANSLATE_ENDPOINT}/v1/translate/#{task_id}")
    http = Net::HTTP.new(uri.host, uri.port)
    http.read_timeout = 5
    
    request = Net::HTTP::Get.new(uri.path)
    response = http.request(request)
    
    # タスクが見つからない（削除済み）
    if response.code == '404'
      return { status: 'cancelled' }.to_json
    end
    
    unless response.code == '200'
      status 500
      return { error: "ステータス取得に失敗しました" }.to_json
    end

    progress_data = JSON.parse(response.body)
    state = progress_data['state']
    
    if state == 'PROGRESS'
      info = progress_data['info']
      current = info['n'] || 0
      total = info['total'] || 0
      progress = total > 0 ? (current.to_f / total * 100).round(1) : 0
      
      {
        status: 'progress',
        current: current,
        total: total,
        progress: progress
      }.to_json
      
    elsif state == 'SUCCESS'
      # 完了時、mono/dualファイルをダウンロードして保存
      timestamp = Time.now.strftime('%Y%m%d_%H%M%S')
      mono_filename = "#{timestamp}_#{task_id}_mono.pdf"
      dual_filename = "#{timestamp}_#{task_id}_dual.pdf"
      
      mono_path = File.join(PDF_DIR, mono_filename)
      dual_path = File.join(PDF_DIR, dual_filename)
      
      # まだダウンロードしていない場合のみダウンロード
      unless File.exist?(mono_path) && File.exist?(dual_path)
        # monoダウンロード
        begin
          mono_uri = URI.parse("#{PDF_TRANSLATE_ENDPOINT}/v1/translate/#{task_id}/mono")
          mono_http = Net::HTTP.new(mono_uri.host, mono_uri.port)
          mono_http.read_timeout = 60
          mono_response = mono_http.request(Net::HTTP::Get.new(mono_uri.path))
          if mono_response.code == '200'
            File.open(mono_path, 'wb') { |f| f.write(mono_response.body) }
            logger.info "Mono PDF saved: #{mono_path}"
          end
        rescue => e
          logger.error "Failed to download mono: #{e.message}"
        end
        
        # dualダウンロード
        begin
          dual_uri = URI.parse("#{PDF_TRANSLATE_ENDPOINT}/v1/translate/#{task_id}/dual")
          dual_http = Net::HTTP.new(dual_uri.host, dual_uri.port)
          dual_http.read_timeout = 60
          dual_response = dual_http.request(Net::HTTP::Get.new(dual_uri.path))
          if dual_response.code == '200'
            File.open(dual_path, 'wb') { |f| f.write(dual_response.body) }
            logger.info "Dual PDF saved: #{dual_path}"
          end
        rescue => e
          logger.error "Failed to download dual: #{e.message}"
        end
      end

      # 保存設定が有効で、かつ未保存の場合のみ記録（1回だけ実行）
      if PDF_TASK_METADATA.key?(task_id) && SAVE_TRANSLATIONS
        meta = PDF_TASK_METADATA.delete(task_id) # 取得と同時に削除して重複保存を防止
        end_time = Time.now
        duration = end_time - meta[:start_time]
        
        metrics = {
          total_time: duration.round(3)
        }
        
        save_pdf_translation(
          task_id,
          meta[:filename],
          meta[:source_lang],
          meta[:target_lang],
          meta[:pages],
          metrics
        )
      end
      
      {
        status: 'success',
        mono_url: "/api/translate-pdf/#{task_id}/mono",
        dual_url: "/api/translate-pdf/#{task_id}/dual"
      }.to_json
      
    elsif state == 'FAILURE'
      PDF_TASK_METADATA.delete(task_id) # 失敗時はメタデータを削除
      { status: 'error', message: '翻訳に失敗しました' }.to_json
      
    else
      { status: 'unknown', state: state }.to_json
    end
    
  rescue StandardError => e
    logger.error "Status check error: #{e.class} - #{e.message}"
    status 500
    { error: e.message }.to_json
  end
end

# PDF翻訳のmonoファイルダウンロード
get '/api/translate-pdf/:task_id/mono' do
  task_id = params['task_id']
  mono_file = Dir.glob(File.join(PDF_DIR, "*#{task_id}_mono.pdf")).first
  
  if mono_file && File.exist?(mono_file)
    send_file mono_file, type: 'application/pdf', disposition: 'attachment'
  else
    status 404
    content_type :json
    { error: "ファイルが見つかりません" }.to_json
  end
end

# PDF翻訳のdualファイルダウンロード
get '/api/translate-pdf/:task_id/dual' do
  task_id = params['task_id']
  dual_file = Dir.glob(File.join(PDF_DIR, "*#{task_id}_dual.pdf")).first
  
  if dual_file && File.exist?(dual_file)
    send_file dual_file, type: 'application/pdf', disposition: 'attachment'
  else
    status 404
    content_type :json
    { error: "ファイルが見つかりません" }.to_json
  end
end

# PDF翻訳の中止
delete '/api/translate-pdf/:task_id' do
  content_type :json
  task_id = params['task_id']
  
  begin
    uri = URI.parse("#{PDF_TRANSLATE_ENDPOINT}/v1/translate/#{task_id}")
    http = Net::HTTP.new(uri.host, uri.port)
    http.read_timeout = 10
    
    request = Net::HTTP::Delete.new(uri.path)
    response = http.request(request)
    
    if response.code == '200' || response.code == '404'
      logger.info "Task #{task_id} deleted"
      PDF_TASK_METADATA.delete(task_id) # 中止時もメタデータを削除
      { success: true }.to_json
    else
      logger.error "Failed to delete task: #{response.code}"
      status response.code.to_i
      { error: "タスクの削除に失敗しました" }.to_json
    end
    
  rescue => e
    logger.error "Delete error: #{e.message}"
    status 500
    { error: e.message }.to_json
  end
end

# ヘルスチェック
get '/health' do
  content_type :json
  { status: 'ok' }.to_json
end

logger.info "=== LocaLingo Starting ==="
logger.info "LLM Endpoint: #{LLM_ENDPOINT}"
logger.info "PDF Translate Endpoint: #{PDF_TRANSLATE_ENDPOINT}"
logger.info "Server will run on http://0.0.0.0:4567"
