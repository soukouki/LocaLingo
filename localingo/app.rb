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
TRANSLATIONS_FILE = 'data/translations.json'
SAVE_TRANSLATIONS = ENV['SAVE_TRANSLATIONS'] != 'false' # デフォルトはtrue

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

# 翻訳結果をJSONファイルに保存する
def save_translation(input_text, output_text, source_lang, target_lang, metrics)
  translations = []
  if File.exist?(TRANSLATIONS_FILE)
    content = File.read(TRANSLATIONS_FILE)
    translations = JSON.parse(content) rescue []
  end

  translation_record = {
    timestamp: Time.now.iso8601,
    source_lang: source_lang,
    target_lang: target_lang,
    input: input_text,
    output: output_text,
    metrics: metrics
  }

  translations << translation_record
  File.write(TRANSLATIONS_FILE, JSON.pretty_generate(translations))
  logger.info "Translation saved to #{TRANSLATIONS_FILE}"
rescue => e
  logger.error "Failed to save translation: #{e.message}"
end

# トップページの表示
get '/' do
  send_file File.join(settings.public_folder, 'index.html')
end

class StopInference < StandardError; end

# 翻訳APIエンドポイント(Server-Sent Events形式でストリーミング)
post '/api/translate' do
  content_type 'text/event-stream'
  
  stream :keep_open do |out|
    begin
      # リクエストボディをパース
      request_body = JSON.parse(request.body.read)
      text = request_body['text']
      source_lang = request_body['source_lang'] || 'auto'
      target_lang = request_body['target_lang'] || 'auto'

      logger.info "=== Translation Request ==="
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
          stream: true  # ストリーミングモードを有効化
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
                  save_translation(text, accumulated_output, source_lang, target_lang, metrics)
                  translation_saved = true
                end
                
                out << "data: #{JSON.generate({ done: true })}\n\n"
                next
              end

              begin
                json = JSON.parse(data)
                content = json.dig('choices', 0, 'delta', 'content')
                
                if content
                  # plamo-2-translateにおいて、このトークンが出てきたら翻訳失敗を意味する
                  if content.include?("<|plamo:reserved:0x1E|>")
                    logger.error "Translation failed token detected."
                    out << "data: #{JSON.generate({ error: "翻訳に失敗しました。" })}\n\n"
                    if SAVE_TRANSLATIONS && !translation_saved
                      metrics = {
                        token_count: token_count,
                        time_to_first_token: first_token_time ? (first_token_time - start_time).round(3) : 0,
                        total_time: (Time.now - start_time).round(3),
                        tokens_per_sec: token_count > 0 ? (token_count / (Time.now - start_time)).round(2) : 0
                      }
                      save_translation(text, accumulated_output, source_lang, target_lang, metrics)
                      translation_saved = true
                    end
                    # これ以上の処理を中断
                    raise StopInference
                  end
                  
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
                    save_translation(text, accumulated_output, source_lang, target_lang, metrics)
                    translation_saved = true
                  end
                  
                  out << "data: #{JSON.generate({ done: true })}\n\n"
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
                  save_translation(text, accumulated_output, source_lang, target_lang, metrics)
                  translation_saved = true
                end
                
                out << "data: #{JSON.generate({ done: true })}\n\n"
              end
            end
          end
        end
      end

      logger.info "=== Translation Complete ==="

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

# ヘルスチェックエンドポイント
get '/health' do
  content_type :json
  { status: 'ok' }.to_json
end

logger.info "=== LocaLingo Starting ==="
logger.info "LLM Endpoint: #{LLM_ENDPOINT}"
logger.info "Server will run on http://0.0.0.0:4567"
