# LocaLingo

[日本語版はこちら](README-ja.md)

LocaLingo is a translation web UI that utilizes PLaMo's specialized large language model for machine translation, developed by Preferred Networks. It operates in tandem with local LLM servers supporting OpenAI-compatible APIs, including LM Studio and Ollama.

## Features

- **Unrestricted character limit**: While conventional translation tools typically impose 2,000-character limits, LocaLingo has no such restrictions. The maximum length depends on the capabilities of the connected LLM server, but translations can span tens of thousands or even hundreds of thousands of characters.
- **Local operation**: Eliminates the need for internet connectivity while maintaining data privacy. All translation processing occurs entirely on your local machine.
- **User-friendly interface**: Provides an intuitive user interface that makes translation tasks straightforward.

## Setup Instructions

### Preparing Your Local LLM Server

1. Install and launch a local LLM server supporting OpenAI-compatible APIs, such as LM Studio or Ollama.
2. Follow instructions from [pfnet/plamo-2-translate · Hugging Face](https://huggingface.co/pfnet/plamo-2-translate) or [mmnga/plamo-2-translate-gguf · Hugging Face](https://huggingface.co/mmnga/plamo-2-translate-gguf) or other documentation to load the PLaMo translation model onto the LLM server.
3. Verify that your LLM server is running via OpenAI-compatible APIs. For LM Studio specifically, you need to enable the "Serve on Local Network" option.

Test your LLM server's operation by executing the following curl command. Adjust the port number and endpoint according to the specific LLM server you're using:

```bash
curl http://localhost:1234/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "plamo-2-translate",
    "messages": [
      {
        "role": "user",
        "content": "<|plamo:op|>dataset\ntranslation\n\n<|plamo:op|>input lang=English\nHello!\n<|plamo:op|>output lang=Japanese"
      }
    ]
  }'
```

While the PLaMo translation model supports long-form translations, most LLM servers limit the output token length by default. Be sure to properly configure the output token length settings.

### For Local-only Operation Only

1. Open compose.yml and either comment out or remove the section related to tunneling. Also, set the `LLM_ENDPOINT` environment variable to the endpoint of your active LLM server.
2. Run the following command to launch LocaLingo:

```bash
sudo docker-compose up app -d
```

### For External Public Access Using Cloudflare Tunnel

For detailed explanations about Cloudflare, refer to other documentation resources.

1. Open compose.yml and set the `LLM_ENDPOINT` environment variable to the endpoint of your active LLM server.
2. Create a .env file and configure it by setting the Cloudflare Tunnel authentication token in the `TUNNEL_TOKEN` environment variable.
3. As necessary, set up Cloudflare Access. This configuration step is crucial—if omitted, the translation service will become accessible to anyone worldwide.
4. Launch LocaLingo using the following command:

```bash
sudo docker-compose up -d
```

## Important Notes

1. LocaLingo utilizes PLaMo's specialized translation model developed by Preferred Networks. Using the PLaMo translation model requires compliance with the PLaMo Community License. Specifically, individuals and small-to-medium enterprises can use it freely for both personal and commercial purposes, but large-scale commercial usage requires a different license agreement. For details, please refer to: [About the PLaMo Community License](https://tech.preferred.jp/ja/blog/plamo-community-license/) and the [PLaMo Community License Agreement](https://plamo.preferredai.jp/info/plamo-community-license-en).
2. LocaLingo itself does not contain LLM server functionality. To operate it, you must have a local LLM server supporting OpenAI-compatible APIs, such as LM Studio or Ollama.
3. By default, all translations are recorded in LocaLingo's operation. To disable translation data storage, set the `SAVE_TRANSLATIONS` environment variable in compose.yml to `false`.
