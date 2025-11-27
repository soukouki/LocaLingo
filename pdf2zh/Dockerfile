FROM ghcr.io/astral-sh/uv:python3.12-bookworm-slim

WORKDIR /app

ENV PYTHONUNBUFFERED=1

RUN apt-get update && \
    apt-get install --no-install-recommends -y \
      libgl1 \
      libglib2.0-0 \
      libxext6 \
      libsm6 \
      libxrender1 \
      git \
      socat \
      redis-server \
      supervisor && \
    rm -rf /var/lib/apt/lists/*

# pdf2zhはfork版を使用
RUN git clone --depth 1 \
    --branch openai-stop-and-max-tokens \
    https://github.com/soukouki/PDFMathTranslate.git \
    PDFMathTranslate

WORKDIR /app/PDFMathTranslate

# pdf2zh の必要ライブラリ
RUN uv pip install --system --no-cache -r pyproject.toml && \
    uv pip install --system --no-cache . && \
    uv pip install --system --no-cache -U "babeldoc<0.3.0" "pymupdf<1.25.3" "pdfminer-six==20250416"

RUN pip install --no-cache-dir .[backend]

WORKDIR /app

RUN mkdir -p /etc/supervisor/conf.d
COPY pdf2zh.conf /etc/supervisor/conf.d/pdf2zh.conf

WORKDIR /app/PDFMathTranslate

EXPOSE 11007

CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/conf.d/pdf2zh.conf"]
