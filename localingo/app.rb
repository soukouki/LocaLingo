require 'sinatra'
require 'gemoji'
require 'json'
require 'net/http'
require 'uri'
require 'logger'
require 'fileutils'

set :port, 4567
set :bind, '0.0.0.0'

logger = Logger.new(STDOUT)
logger.level = Logger::INFO
STDOUT.sync = true

set :public_folder, 'public'

LLM_ENDPOINT = ENV['LLM_ENDPOINT'] || 'http://lmstudio:1234'
TRANSLATIONS_FILE = 'data/translations.json'

def replace_emoji(text)
  regexp = Regexp.new((Emoji.all.map(&:raw)-["*️⃣"]+["\\*️⃣"]).join('|'))
  text.gsub(regexp) do |emoji|
    e = Emoji.find_by_unicode(emoji)
    logger.debug "Found emoji: #{emoji} -> #{e.aliases.first if e}"
    e ? ":#{e.aliases.first}:" : emoji
  end
end

def save_translation(input_text, output_text, direction, metrics)
  translations = []
  if File.exist?(TRANSLATIONS_FILE)
    content = File.read(TRANSLATIONS_FILE)
    translations = JSON.parse(content) rescue []
  end

  translation_record = {
    timestamp: Time.now.iso8601,
    direction: direction,
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

get '/' do
  send_file File.join(settings.public_folder, 'index.html')
end

post '/api/translate' do
  content_type 'text/event-stream'
  
  stream :keep_open do |out|
    begin
      request_body = JSON.parse(request.body.read)
      text = request_body['text']
      direction = request_body['direction']

      logger.info "=== Translation Request ==="
      logger.info "Direction: #{direction}"
      logger.info "Text length: #{text&.length || 0}"
      logger.info "LLM Endpoint: #{LLM_ENDPOINT}"

      input_lang, output_lang = case direction
      when 'en-ja'
        ['English', 'Japanese']
      when 'ja-en'
        ['Japanese', 'English']
      else
        ['English', 'Japanese']
      end

      replaced_text = replace_emoji(text)
      print(replaced_text)
      prompt = "<|plamo:op|>dataset\ntranslation\n\n<|plamo:op|>input lang=#{input_lang}\n#{replaced_text}\n<|plamo:op|>output lang=#{output_lang}"
      
      logger.info "Generated prompt (first 100 chars): #{prompt[0..100]}..."

      uri = URI.parse("#{LLM_ENDPOINT}/v1/chat/completions")
      logger.info "Connecting to: #{uri}"

      token_count = 0
      accumulated_output = ""
      start_time = Time.now
      first_token_time = nil
      
      Net::HTTP.start(uri.host, uri.port, read_timeout: 300) do |http|
        request = Net::HTTP::Post.new(uri.path)
        request['Content-Type'] = 'application/json'
        request.body = {
          model: 'plamo-2-translate',
          messages: [
            { role: 'user', content: prompt }
          ],
          stream: true
        }.to_json

        logger.info "Sending request to LLM..."

        http.request(request) do |response|
          logger.info "Response status: #{response.code}"
          logger.info "Response headers: #{response.to_hash.inspect}"
          
          unless response.code == '200'
            logger.error "HTTP Error: #{response.code} #{response.message}"
            out << "data: #{JSON.generate({ error: "HTTP #{response.code}: #{response.message}" })}\n\n"
            next
          end

          buffer = ''
          response.read_body do |chunk|
            logger.debug "Received chunk: #{chunk.bytesize} bytes"
            
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
                
                logger.info "Stream completed. Total tokens: #{token_count}"
                logger.info "Time to first token: #{time_to_first_token.round(3)}s"
                logger.info "Total time: #{total_time.round(3)}s"
                logger.info "Tokens/sec: #{tokens_per_sec.round(2)}"
                
                metrics = {
                  token_count: token_count,
                  time_to_first_token: time_to_first_token.round(3),
                  total_time: total_time.round(3),
                  tokens_per_sec: tokens_per_sec.round(2)
                }
                
                save_translation(text, accumulated_output, direction, metrics)
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
                  logger.debug "Token ##{token_count}: #{content.inspect}"
                  
                  out << "data: #{JSON.generate({ token: content })}\n\n"
                end

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
                  
                  metrics = {
                    token_count: token_count,
                    time_to_first_token: time_to_first_token.round(3),
                    total_time: total_time.round(3),
                    tokens_per_sec: tokens_per_sec.round(2)
                  }
                  
                  save_translation(text, accumulated_output, direction, metrics)
                  out << "data: #{JSON.generate({ done: true })}\n\n"
                end
              rescue JSON::ParserError => e
                logger.error "JSON parse error: #{e.message}"
                logger.error "Problematic data: #{data}"
              end
            end
          end
          
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
                
                metrics = {
                  token_count: token_count,
                  time_to_first_token: time_to_first_token.round(3),
                  total_time: total_time.round(3),
                  tokens_per_sec: tokens_per_sec.round(2)
                }
                
                save_translation(text, accumulated_output, direction, metrics)
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
      out << "data: #{JSON.generate({ error: "LLMサーバーに接続できません: #{LLM_ENDPOINT}" })}\n\n"
      
    rescue Errno::EHOSTUNREACH => e
      logger.error "=== Host Unreachable ==="
      logger.error "Cannot reach LLM endpoint: #{LLM_ENDPOINT}"
      out << "data: #{JSON.generate({ error: "LLMサーバーに到達できません: #{LLM_ENDPOINT}" })}\n\n"
      
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

get '/health' do
  content_type :json
  { status: 'ok', llm_endpoint: LLM_ENDPOINT }.to_json
end

logger.info "=== LocaLingo Starting ==="
logger.info "LLM Endpoint: #{LLM_ENDPOINT}"
logger.info "Server will run on http://0.0.0.0:4567"
