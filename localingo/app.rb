require 'sinatra'
require 'gemoji'
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
STDOUT.sync = true  # 即座にログを出力

set :public_folder, 'public'

# 環境変数から設定を読み込む
LLM_ENDPOINT = ENV['LLM_ENDPOINT'] || 'http://host.docker.internal:1234'
PDF_TRANSLATE_ENDPOINT = ENV['PDF_TRANSLATE_ENDPOINT'] || 'http://pdf2zh:11007'
TRANSLATIONS_FILE = 'data/translations.json'
PDF_DIR = 'data/pdfs'
SAVE_TRANSLATIONS = ENV['SAVE_TRANSLATIONS'] != 'false' # デフォルトはtrue

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
  'auto' => 'English|Japanese'  # 自動検知
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
      # リクエストボディをパース
      request_body = JSON.parse(request.body.read)
      text = request_body['text']
      source_lang = request_body['source_lang'] || 'auto'
      target_lang = request_body['target_lang'] || 'auto'

      logger.info "=== Text Translation Request ==="
      logger.info "Source: #{source_lang} (#{LANGUAGE_MAP[source_lang]})"
      logger.info "Target: #{target_lang} (#{LANGUAGE_MAP[target_lang]})"
      logger.info "Text length: #{text&.length || 0}"
      logger.info "LLM Endpoint: #{LLM_ENDPOINT}"

      # 言語コードを実際の言語名に変換
      input_lang = LANGUAGE_MAP[source_lang] || LANGUAGE_MAP['auto']
      output_lang = LANGUAGE_MAP[target_lang] || LANGUAGE_MAP['auto']
      
      # plamo-2-translate用のプロンプトフォーマット
      prompt = "<|plamo:op|>dataset\ntranslation\n\n<|plamo:op|>input lang=#{input_lang}\n#{text}<|plamo:op|>output lang=#{output_lang}"
      
      logger.info "Generated prompt (first 100 chars): #{prompt[0..100]}..."

      uri = URI.parse("#{LLM_ENDPOINT}/v1/chat/completions")
      logger.info "Connecting to: #{uri}"

      # メトリクス計測用の変数
      token_count = 0
      accumulated_output = ""  # ストリーミングで受信した全テキスト
      start_time = Time.now
      first_token_time = nil
      translation_saved = false  # 翻訳結果の重複保存を防ぐフラグ
      
      Net::HTTP.start(uri.host, uri.port, read_timeout: 300) do |http|
        request = Net::HTTP::Post.new(uri.path)
        request['Content-Type'] = 'application/json'
        request.body = {
          model: 'plamo-2-translate',
          messages: [
            { role: 'user', content: prompt }
          ],
          stop: ["<|plamo:op|>", "<|plamo:reserved:0x1E|>"],
          stream: true, # ストリーミングモードを有効化
        }.to_json

        logger.info "Sending request to LLM..."

        http.request(request) do |response|
          logger.info "Response status: #{response.code}"
          logger.info "Response headers: #{response.to_hash.inspect}"
          
          # HTTPエラーチェック
          unless response.code == '200'
            logger.error "HTTP Error: #{response.code} #{response.message}"
            out << "data: #{JSON.generate({ error: "HTTP #{response.code}: #{response.message}" })}\n\n"
            next
          end

          buffer = ''  # 不完全な行を一時的に保存するバッファ
          
          response.read_body do |chunk|
            logger.debug "Received chunk: #{chunk.bytesize} bytes"
            
            buffer += chunk
            
            # -1を指定すると、末尾が\nで終わる場合も空文字列を保持する
            # これにより、不完全な行をバッファに残すことができる
            lines = buffer.split("\n", -1)
            
            # 最後の要素(不完全な可能性がある行)を次回に持ち越す
            buffer = lines.pop || ''
            
            # 完全な行のみを処理
            lines.each do |line|
              line = line.strip
              next if line.empty?
              next unless line.start_with?('data: ')

              data = line.sub('data: ', '').strip

              # ストリーム終了シグナル
              if data == '[DONE]'
                end_time = Time.now
                total_time = end_time - start_time
                time_to_first_token = first_token_time ? first_token_time - start_time : 0
                tokens_per_sec = token_count > 0 ? token_count / total_time : 0
                
                logger.info "Stream completed. Total tokens: #{token_count}"
                logger.info "Time to first token: #{time_to_first_token.round(3)}s"
                logger.info "Total time: #{total_time.round(3)}s"
                logger.info "Tokens/sec: #{tokens_per_sec.round(2)}"
                
                # 未保存の場合のみ翻訳結果を保存
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
                  first_token_time ||= Time.now  # 最初のトークン受信時刻を記録
                  accumulated_output += content
                  logger.debug "Token ##{token_count}: #{content.inspect}"
                  
                  # クライアントにトークンを送信
                  out << "data: #{JSON.generate({ token: content })}\n\n"
                end

                # 生成完了シグナル
                finish_reason = json.dig('choices', 0, 'finish_reason')
                if finish_reason == 'stop'
                  end_time = Time.now
                  total_time = end_time - start_time
                  time_to_first_token = first_token_time ? first_token_time - start_time : 0
                  tokens_per_sec = token_count > 0 ? token_count / total_time : 0
                  
                  logger.info "Finish reason: stop. Total tokens: #{token_count}"
                  logger.info "Time to first token: #{time_to_first_token.round(3)}s"
                  logger.info "Total time: #{total_time.round(3)}s"
                  logger.info "Tokens/sec: #{tokens_per_sec.round(2)}"
                  
                  # 未保存の場合のみ翻訳結果を保存
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
                  
                  if token_count == 0
                    logger.warn "No tokens were generated before finish."
                    out << "data: #{JSON.generate({ error: "翻訳に失敗しました" })}\n\n"
                  else
                    out << "data: #{JSON.generate({ done: true })}\n\n"
                  end
                  next
                end
              rescue JSON::ParserError => e
                logger.error "JSON parse error: #{e.message}"
                logger.error "Problematic data: #{data}"
              end
            end
          end
          
          # read_body完了後、バッファに残ったデータを処理
          unless buffer.empty?
            logger.debug "Processing remaining buffer: #{buffer}"
            if buffer.start_with?('data: ')
              data = buffer.sub('data: ', '').strip
              if data == '[DONE]'
                end_time = Time.now
                total_time = end_time - start_time
                time_to_first_token = first_token_time ? first_token_time - start_time : 0
                tokens_per_sec = token_count > 0 ? token_count / total_time : 0
                
                logger.info "Stream completed (buffer). Total tokens: #{token_count}"
                logger.info "Time to first token: #{time_to_first_token.round(3)}s"
                logger.info "Total time: #{total_time.round(3)}s"
                logger.info "Tokens/sec: #{tokens_per_sec.round(2)}"
                
                # 未保存の場合のみ翻訳結果を保存
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

      logger.info "=== Text Translation Complete ==="

    rescue Errno::ECONNREFUSED => e
      logger.error "=== Connection Refused ==="
      logger.error "Cannot connect to LLM endpoint: #{LLM_ENDPOINT}"
      logger.error "Please check if the LLM server is running"
      out << "data: #{JSON.generate({ error: "LLMサーバーに接続できません" })}\n\n"
      
    rescue Errno::EHOSTUNREACH => e
      logger.error "=== Host Unreachable ==="
      logger.error "Cannot reach LLM endpoint: #{LLM_ENDPOINT}"
      out << "data: #{JSON.generate({ error: "LLMサーバーに到達できません" })}\n\n"
      
    rescue SocketError => e
      logger.error "=== Socket Error ==="
      logger.error "DNS or network error: #{e.message}"
      out << "data: #{JSON.generate({ error: "ネットワークエラー: #{e.message}" })}\n\n"
      
    rescue StandardError => e
      logger.error "=== Error occurred ==="
      logger.error "Error class: #{e.class}"
      logger.error "Error message: #{e.message}"
      logger.error "Backtrace:"
      e.backtrace.first(10).each { |line| logger.error "  #{line}" }
      
      out << "data: #{JSON.generate({ error: e.message })}\n\n"
    ensure
      out.close
    end
  end
end

# PDF翻訳APIエンドポイント(Server-Sent Events形式でストリーミング)
post '/api/translate-pdf' do
  content_type 'text/event-stream'
  
  stream :keep_open do |out|
    task_id = nil
    
    begin
      # マルチパートフォームデータからパラメータを取得
      pdf_file = params['file']
      source_lang = params['source_lang'] || 'en'
      target_lang = params['target_lang'] || 'ja'
      pages = params['pages'] # オプション: 翻訳するページ範囲

      unless pdf_file && pdf_file[:tempfile]
        out << "data: #{JSON.generate({ error: "PDFファイルがアップロードされていません" })}\n\n"
        next
      end

      original_filename = pdf_file[:filename]
      logger.info "=== PDF Translation Request ==="
      logger.info "File: #{original_filename}"
      logger.info "Source: #{source_lang} (#{LANGUAGE_MAP[source_lang]})"
      logger.info "Target: #{target_lang} (#{LANGUAGE_MAP[target_lang]})"
      logger.info "PDF Translate Endpoint: #{PDF_TRANSLATE_ENDPOINT}"

      # 言語コードを実際の言語名に変換
      lang_in = LANGUAGE_MAP[source_lang] || 'English'
      lang_out = LANGUAGE_MAP[target_lang] || 'Japanese'

      # プロンプトの作成
      prompt = "<|plamo:op|>dataset\ntranslation\n<|plamo:op|>input lang=${lang_in}\n${text}\n<|plamo:op|>output lang=${lang_out}"

      # PDFMathTranslateのAPIにタスクを送信
      uri = URI.parse("#{PDF_TRANSLATE_ENDPOINT}/v1/translate")
      
      # マルチパート形式でリクエストを作成
      boundary = "----WebKitFormBoundary#{rand(1000000000)}"
      
      # データペイロードの作成
      data_payload = {
        lang_in: lang_in,
        lang_out: lang_out,
        service: "openailiked",
        thread: 10,
        prompt: prompt
      }
      
      # ページ指定がある場合は追加
      if pages && !pages.empty?
        data_payload[:pages] = pages.is_a?(String) ? JSON.parse(pages) : pages
      end

      post_body = []
      
      # ファイルパート
      post_body << "--#{boundary}\r\n"
      post_body << "Content-Disposition: form-data; name=\"file\"; filename=\"#{original_filename}\"\r\n"
      post_body << "Content-Type: application/pdf\r\n\r\n"
      post_body << pdf_file[:tempfile].read
      post_body << "\r\n"
      
      # データパート
      post_body << "--#{boundary}\r\n"
      post_body << "Content-Disposition: form-data; name=\"data\"\r\n\r\n"
      post_body << data_payload.to_json
      post_body << "\r\n"
      
      post_body << "--#{boundary}--\r\n"
      
      body = post_body.join

      # タスク送信
      http = Net::HTTP.new(uri.host, uri.port)
      http.read_timeout = 10
      
      request = Net::HTTP::Post.new(uri.path)
      request['Content-Type'] = "multipart/form-data; boundary=#{boundary}"
      request.body = body

      logger.info "Submitting PDF translation task..."
      
      response = http.request(request)
      
      unless response.code == '200'
        logger.error "Failed to submit task: #{response.code} #{response.message}"
        out << "data: #{JSON.generate({ error: "翻訳タスクの送信に失敗しました: #{response.message}" })}\n\n"
        next
      end

      task_response = JSON.parse(response.body)
      task_id = task_response['id']
      
      unless task_id
        logger.error "No task ID returned"
        out << "data: #{JSON.generate({ error: "タスクIDが取得できませんでした" })}\n\n"
        next
      end

      logger.info "Task submitted successfully: #{task_id}"
      out << "data: #{JSON.generate({ task_id: task_id, status: 'submitted' })}\n\n"

      # 元のPDFを保存
      timestamp = Time.now.strftime('%Y%m%d_%H%M%S')
      saved_filename = "#{timestamp}_#{task_id}_original.pdf"
      saved_path = File.join(PDF_DIR, saved_filename)
      
      pdf_file[:tempfile].rewind
      File.open(saved_path, 'wb') do |f|
        f.write(pdf_file[:tempfile].read)
      end
      logger.info "Original PDF saved: #{saved_path}"

      # 進捗のポーリング開始
      start_time = Time.now
      last_progress = 0
      total_pages = nil
      progress_uri = URI.parse("#{PDF_TRANSLATE_ENDPOINT}/v1/translate/#{task_id}")
      
      loop do
        sleep 0.2 # 秒間5回ポーリング
        
        begin
          progress_http = Net::HTTP.new(progress_uri.host, progress_uri.port)
          progress_http.read_timeout = 5
          progress_request = Net::HTTP::Get.new(progress_uri.path)
          progress_response = progress_http.request(progress_request)
          
          if progress_response.code == '200'
            progress_data = JSON.parse(progress_response.body)
            state = progress_data['state']
            
            if state == 'PROGRESS'
              info = progress_data['info']
              current = info['n'] || 0
              total = info['total'] || 0
              total_pages ||= total
              
              if total > 0
                progress_percent = (current.to_f / total * 100).round(1)
                
                # 推定残り時間の計算
                elapsed_time = Time.now - start_time
                if current > 0
                  estimated_total_time = elapsed_time / current * total
                  estimated_remaining = estimated_total_time - elapsed_time
                else
                  estimated_remaining = 0
                end
                
                logger.info "Progress: #{current}/#{total} (#{progress_percent}%) - ETA: #{estimated_remaining.round(0)}s"
                
                out << "data: #{JSON.generate({
                  status: 'progress',
                  current: current,
                  total: total,
                  progress: progress_percent,
                  elapsed: elapsed_time.round(1),
                  estimated_remaining: estimated_remaining.round(0)
                })}\n\n"
                
                last_progress = current
              end
              
            elsif state == 'SUCCESS'
              elapsed_time = Time.now - start_time
              logger.info "Translation completed successfully in #{elapsed_time.round(1)}s"
              
              # 翻訳完了後、mono/dualファイルをダウンロードして保存
              mono_filename = "#{timestamp}_#{task_id}_mono.pdf"
              dual_filename = "#{timestamp}_#{task_id}_dual.pdf"
              
              mono_path = File.join(PDF_DIR, mono_filename)
              dual_path = File.join(PDF_DIR, dual_filename)
              
              # monoファイルのダウンロード
              mono_uri = URI.parse("#{PDF_TRANSLATE_ENDPOINT}/v1/translate/#{task_id}/mono")
              mono_http = Net::HTTP.new(mono_uri.host, mono_uri.port)
              mono_http.read_timeout = 60
              mono_request = Net::HTTP::Get.new(mono_uri.path)
              mono_response = mono_http.request(mono_request)
              
              if mono_response.code == '200'
                File.open(mono_path, 'wb') { |f| f.write(mono_response.body) }
                logger.info "Mono PDF saved: #{mono_path}"
              end
              
              # dualファイルのダウンロード
              dual_uri = URI.parse("#{PDF_TRANSLATE_ENDPOINT}/v1/translate/#{task_id}/dual")
              dual_http = Net::HTTP.new(dual_uri.host, dual_uri.port)
              dual_http.read_timeout = 60
              dual_request = Net::HTTP::Get.new(dual_uri.path)
              dual_response = dual_http.request(dual_request)
              
              if dual_response.code == '200'
                File.open(dual_path, 'wb') { |f| f.write(dual_response.body) }
                logger.info "Dual PDF saved: #{dual_path}"
              end
              
              # 翻訳ログの保存
              if SAVE_TRANSLATIONS
                metrics = {
                  total_time: elapsed_time.round(1),
                  total_pages: total_pages,
                  mono_file: mono_filename,
                  dual_file: dual_filename,
                  original_file: saved_filename
                }
                save_pdf_translation(task_id, original_filename, source_lang, target_lang, data_payload[:pages], metrics)
              end
              
              out << "data: #{JSON.generate({ 
                status: 'success', 
                task_id: task_id,
                mono_url: "/api/translate-pdf/#{task_id}/mono",
                dual_url: "/api/translate-pdf/#{task_id}/dual",
                elapsed: elapsed_time.round(1)
              })}\n\n"
              
              break
              
            elsif state == 'FAILURE'
              logger.error "Translation failed"
              out << "data: #{JSON.generate({ error: "翻訳に失敗しました" })}\n\n"
              break
              
            else
              logger.warn "Unknown state: #{state}"
            end
          else
            logger.error "Failed to get progress: #{progress_response.code}"
          end
          
        rescue => e
          logger.error "Error polling progress: #{e.message}"
        end
      end

      logger.info "=== PDF Translation Complete ==="

    rescue StandardError => e
      logger.error "=== Error occurred ==="
      logger.error "Error class: #{e.class}"
      logger.error "Error message: #{e.message}"
      logger.error "Backtrace:"
      e.backtrace.first(10).each { |line| logger.error "  #{line}" }
      
      out << "data: #{JSON.generate({ error: e.message })}\n\n"
    ensure
      out.close
    end
  end
end

# PDF翻訳のmonoファイルダウンロード
get '/api/translate-pdf/:task_id/mono' do
  task_id = params['task_id']
  
  # dataディレクトリ内でtask_idを含むmonoファイルを検索
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
  
  # dataディレクトリ内でtask_idを含むdualファイルを検索
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
    
    if response.code == '200'
      logger.info "Task #{task_id} deleted successfully"
      { success: true }.to_json
    else
      logger.error "Failed to delete task: #{response.code}"
      status response.code.to_i
      { error: "タスクの削除に失敗しました" }.to_json
    end
    
  rescue => e
    logger.error "Error deleting task: #{e.message}"
    status 500
    { error: e.message }.to_json
  end
end

# ヘルスチェックエンドポイント
get '/health' do
  content_type :json
  { status: 'ok' }.to_json
end

logger.info "=== LocaLingo Starting ==="
logger.info "LLM Endpoint: #{LLM_ENDPOINT}"
logger.info "PDF Translate Endpoint: #{PDF_TRANSLATE_ENDPOINT}"
logger.info "Server will run on http://0.0.0.0:4567"
