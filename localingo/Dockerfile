FROM ruby:3.2-slim

# 作業ディレクトリを設定
WORKDIR /app

# 必要なパッケージをインストール
RUN apt-get update -qq && \
    apt-get install -y build-essential libssl-dev && \
    rm -rf /var/lib/apt/lists/*

# GemfileとGemfile.lockをコピー
COPY Gemfile* ./

# Bundlerで依存関係をインストール
RUN bundle install

# アプリケーションファイルをコピー
COPY app.rb ./
COPY public ./public

# ポートを公開
EXPOSE 4567

# Sinatraアプリを起動
CMD ["ruby", "app.rb"]
