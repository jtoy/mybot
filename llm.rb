# Unified Llm Class for Rails and Standalone Applications

# Require necessary libraries
require 'dotenv/load'
require "active_support" 
require "active_support/core_ext/hash/indifferent_access" 
require 'digest'
require 'json'
require 'http'
require 'anthropic'
require 'gemini-ai'
require "openai"

class Llm
  SERVICES = {
    "gemini" => ["gemini-1.5-flash", "gemini-1.5-flash-002"],
    "openai" => ["gpt-4o-mini", "gpt-4o"],
    "groq" => ["llama-3.1-70b-versatile", "llama-3.1-8b-instant"],
    "claude" => ["claude-3-5-sonnet-20240620", "claude-3-5-sonnet-20241022"],
    "local" => ["llama3.1"]
  }

  DEFAULT_MODELS = {
    "gemini" => "gemini-1.5-flash",
    "openai" => "gpt-4o-mini",
    "groq" => "llama-3.1-70b-versatile",
    "claude" => "claude-3-5-sonnet-20240620",
    "local" => "llama3.1"
  }

  RateLimitError = Class.new(StandardError)

  class << self
    # Helper method to retrieve API keys
    def fetch_key(env_key, credential_key = nil)
      if defined?(Rails)
        Rails.application.credentials.dig(credential_key || env_key.downcase)
      else
        ENV[env_key]
      end
    end

    # Helper method to check if Rails is in production
    def production?
      if defined?(Rails)
        Rails.env.production?
      else
        ENV["RAILS_ENV"] == "production"
      end
    end

    # Helper method for logging
    def log(message, article_id = nil)
      if defined?(App) && App.respond_to?(:pd)
        App.pd(message, article_id)
      else
        puts message
      end
    end

    # Helper method for caching
    def cached_get(cache_name)
      if defined?(App) && App.respond_to?(:redis)
        App.redis.get(cache_name)
      else
        nil
      end
    end

    def cached_set(cache_name, value)
      if defined?(App) && App.respond_to?(:redis)
        App.redis.set(cache_name, value)
      end
    end

    # Initialize OpenAI client
    def client
      key = ENV["OPENAI_KEY"] || fetch_key("OPENAI_KEY", :openai_key)
      OpenAI::Client.new(access_token: key, request_timeout: 480)
    end

    # Parse output to JSON with error handling
    def to_json_output(output, opts = {})
      json = JSON.parse(output).with_indifferent_access rescue nil
      llm = opts.key?(:llm) ? opts[:llm] : true
      return json if json

      regex = /```(.*?)```/
      matches = output.scan(regex)
      if matches.any?
        log "CODE REGEX FIXED JSON!!!"
        json = JSON.parse(matches.first).with_indifferent_access rescue nil
        return json if json
      end

      json_objects = []
      json_pattern = /{.*?}/m
      output.scan(json_pattern) do |match|
        begin
          json_data = JSON.parse(match).with_indifferent_access
          json_objects << json_data
        rescue JSON::ParserError
          next
        end
      end

      if json_objects.any?
        log "JSON REGEX FIXED JSON!!!"
        json_objects = json_objects.first if json_objects.size == 1
        return json_objects
      end

      json_regex = /(\{.*\}|\[.*\])/m
      match = json_regex.match(output)
      if match
        begin
          return JSON.parse(match[0])
        rescue JSON::ParserError
        end
      end

      log "WTF needed to clean with LLM"

      if llm
        r = go(prompt: "Extract all the JSON from the below text:\n\n#{output}") rescue nil
        to_json_output(r, llm: false)
      else
        nil
      end
    end

    # Local model handler
    def local(opts = {})
      url = opts[:url]
      prompt = opts[:prompt]
      model = opts[:model] || "llama3.1"

      if url.nil? || url.empty?
        url = production? ? "http://dispenza.duckdns.org:11434" : "http://localhost:11434"
        log url unless production?
      end

      data = { model: model, prompt: prompt, stream: false }
      log data.inspect
      log 'wtf'

      response = HTTP.post("#{url}/api/generate", json: data)
      json = JSON.parse(response.body.to_s) rescue {}
      json['response']
    end

    # DeepInfra (groq) model handler
    def groq(opts = {})
      prompt = opts[:prompt]
      model = opts[:model] || "llama-3.1-8b-instant"
      retry_limit = opts[:retry_limit] || 100
      retry_count = 0
      request_body = {
        messages: [{ role: "user", content: prompt }],
        model: model
      }

      key = ENV["GROQ_API_KEY"] || fetch_key("GROQ_API_KEY", :groq_api_key)

      begin
        response = HTTP.headers(
          "Authorization" => "Bearer #{key}",
          "Content-Type" => "application/json"
        ).post("https://api.groq.com/openai/v1/chat/completions", json: request_body)

        json = JSON.parse(response.to_s) 
        log json.inspect
        log "RETRY COUNT #{retry_count}"

        if json.dig('error', 'code') == 'rate_limit_exceeded'
          wait_time = response.headers["retry-after"].to_i
          log "Rate limit reached. Retrying in #{wait_time} seconds..."
          sleep(wait_time)
          retry_count += 1
          raise RateLimitError, 'Rate limit reached'
        end

        json.dig('choices', 0, 'message', 'content')
      rescue RateLimitError => e
        log "Rate limit error: #{e}. Retry count: #{retry_count}"
        log prompt
        retry if (retry_count += 1) <= retry_limit
        nil
      end
    end

    # Claude model handler
    def claude(opts = {})
      client = Anthropic::Client.new(access_token: ENV["CLAUDE_API_KEY"] || fetch_key("CLAUDE_API_KEY", :claude_key))
      model = opts[:model] || "claude-3-5-sonnet-20241022"
      system = opts[:system] || "answer in english"
      messages = opts[:messages] || [{ "role" => "user", "content" => opts[:prompt] }]
      
      raise ArgumentError, "No messages provided" if messages.empty?

      response = client.messages(
        parameters: {
          model: model,
          system: system,
          messages: messages,
          max_tokens: 4096
        }
      )
      response.dig("content", 0, "text")
    end

    # OpenAI model handler
    def openai(opts = {})
      model = opts[:model] || "gpt-4o-mini"
      prompts = opts[:prompts]
      prompt = opts[:prompt]

      if prompts.is_a?(Array)
        response = client.chat(parameters: { model: model, messages: prompts })
      else
        response = client.chat(parameters: { model: model, messages: [{ role: "user", content: prompt }] })
      end

      log response.inspect
      response.dig("choices", 0, "message", "content")
    end

    # Gemini model handler
    def gemini(opts = {})
      prompt = opts[:prompt]
      video_path = opts[:video_path]
      model = opts[:model] || "gemini-1.5-flash-002"
      api_key = ENV["GEMINI_API_KEY"] || fetch_key("GEMINI_API_KEY", :gemini_key)

      client = Gemini.new(
        credentials: {
          service: 'generative-language-api',
          api_key: api_key
        },
        options: { 
          model: model, 
          server_sent_events: true,
          safetySettings: [
            { category: "HARM_CATEGORY_SEXUALLY_EXPLICIT", threshold: "BLOCK_NONE" },
            { category: "HARM_CATEGORY_HATE_SPEECH", threshold: "BLOCK_NONE" },
            { category: "HARM_CATEGORY_HARASSMENT", threshold: "BLOCK_NONE" },
            { category: "HARM_CATEGORY_DANGEROUS_CONTENT", threshold: "BLOCK_NONE" }
          ],
        }
      )

      content = if video_path
                  mime_type = File.extname(video_path).downcase == '.mkv' ? 'video/x-matroska' : 'video/mp4'
                  [
                    { role: 'user', parts: [
                      { text: prompt },
                      { inline_data: { 
                        mime_type: mime_type,
                        data: Base64.strict_encode64(File.read(video_path))
                      } }
                    ]}
                  ]
                else
                  { role: 'user', parts: { text: prompt } }
                end

      result = client.generate_content({ contents: content })
      result.dig('candidates', 0, 'content', 'parts', 0, 'text')
    end

    # GAi model handler
    def gai(prompt, opts = {})
      api_key = ENV["GEMINI_API_KEY"] || fetch_key("GEMINI_API_KEY", :gemini_key)
      model = 'gemini-1.5-flash'
      url = "https://generativelanguage.googleapis.com/v1beta/models/#{model}:generateContent?key=#{api_key}"

      response = HTTP.headers(content_type: "application/json")
                     .post(url, json: {
                       contents: [{
                         parts: [{ text: prompt }]
                       }],
                       safetySettings: [
                         { category: "HARM_CATEGORY_SEXUALLY_EXPLICIT", threshold: "BLOCK_NONE" },
                         { category: "HARM_CATEGORY_HATE_SPEECH", threshold: "BLOCK_NONE" },
                         { category: "HARM_CATEGORY_HARASSMENT", threshold: "BLOCK_NONE" },
                         { category: "HARM_CATEGORY_DANGEROUS_CONTENT", threshold: "BLOCK_NONE" }
                       ],
                       generationConfig: { responseMimeType: "application/json" }
                     })

      log response.body.to_s
      data = JSON.parse(response.body.to_s)
      data.dig("candidates", 0, "content", "parts", 0, "text")
    end

    # Main routing method
    def go(opts = {})
      prompts = opts[:prompts]
      prompt = opts[:prompt]
      model = opts[:model]
      debug = opts.fetch(:debug, false)
      use_cache = opts.fetch(:use_cache, false)
      service = opts[:service] || ENV["SERVICE"] || "gemini"
      max_attempts = opts[:max_attempts] || 1
      attempts = 0
      full_prompt = "#{service}#{model}#{prompts}#{prompt}"
      format = opts[:format] || "json_object"
      cache_name = opts[:cache_name] || "ac:#{Digest::MD5.hexdigest(full_prompt)}"

      log prompt if debug

      if use_cache
        cached_response = cached_get(cache_name)
        if cached_response
          log "USING CACHE #{cache_name}", opts[:article_id]
          return cached_response
        end
      end

      begin
        log "#{service}/#{model}"
        if respond_to?(service)
          response = send(service, opts)
        else
          raise "No service #{service} found"
        end

        if opts[:json] && response.is_a?(String)
          parsed_response = to_json_output(response)
          cached_set(cache_name, parsed_response) if use_cache
          parsed_response
        else
          cached_set(cache_name, response) if use_cache
          response
        end
      rescue StandardError => e
        if attempts < max_attempts
          log("Retrying attempt #{attempts} for #{full_prompt} #{e} #{e.backtrace.join("\n")}", opts[:article_id])
          attempts += 1
          sleep(attempts * 5)
          retry
        else
          log("Out of attempts for #{full_prompt} #{e} #{e.backtrace.join('\n')}")
          nil
        end
      end
    end

    # Prompt improvement method
    def improve_prompt(task_or_prompt)
      meta_prompt = <<~PROMPT.strip
        Given a task description or existing prompt, produce a detailed system prompt to guide a language model in completing the task effectively.

        # Guidelines

        - Understand the Task: Grasp the main objective, goals, requirements, constraints, and expected output.
        - Minimal Changes: If an existing prompt is provided, improve it only if it's simple. For complex prompts, enhance clarity and add missing elements without altering the original structure.
        - Reasoning Before Conclusions**: Encourage reasoning steps before any conclusions are reached. ATTENTION! If the user provides examples where the reasoning happens afterward, REVERSE the order! NEVER START EXAMPLES WITH CONCLUSIONS!
            - Reasoning Order: Call out reasoning portions of the prompt and conclusion parts (specific fields by name). For each, determine the ORDER in which this is done, and whether it needs to be reversed.
            - Conclusion, classifications, or results should ALWAYS appear last.
        - Examples: Include high-quality examples if helpful, using placeholders [in brackets] for complex elements.
           - What kinds of examples may need to be included, how many, and whether they are complex enough to benefit from placeholders.
        - Clarity and Conciseness: Use clear, specific language. Avoid unnecessary instructions or bland statements.
        - Formatting: Use markdown features for readability. DO NOT USE \`\`\` CODE BLOCKS UNLESS SPECIFICALLY REQUESTED.
        - Preserve User Content: If the input task or prompt includes extensive guidelines or examples, preserve them entirely, or as closely as possible. If they are vague, consider breaking down into sub-steps. Keep any details, guidelines, examples, variables, or placeholders provided by the user.
        - Constants: DO include constants in the prompt, as they are not susceptible to prompt injection. Such as guides, rubrics, and examples.
        - Output Format: Explicitly the most appropriate output format, in detail. This should include length and syntax (e.g. short sentence, paragraph, JSON, etc.)
            - For tasks outputting well-defined or structured data (classification, JSON, etc.) bias toward outputting a JSON.
            - JSON should never be wrapped in code blocks (\`\`\`) unless explicitly requested.

        The final prompt you output should adhere to the following structure below. Do not include any additional commentary, only output the completed system prompt. SPECIFICALLY, do not include any additional messages at the start or end of the prompt. (e.g. no "---")

        [Concise instruction describing the task - this should be the first line in the prompt, no section header]

        [Additional details as needed.]

        [Optional sections with headings or bullet points for detailed steps.]

        # Steps [optional]

        [optional: a detailed breakdown of the steps necessary to accomplish the task]

        # Output Format

        [Specifically call out how the output should be formatted, be it response length, structure e.g. JSON, markdown, etc]

        # Examples [optional]

        [Optional: 1-3 well-defined examples with placeholders if necessary. Clearly mark where examples start and end, and what the input and output are. User placeholders as necessary.]
        [If the examples are shorter than what a realistic example is expected to be, make a reference with () explaining how real examples should be longer / shorter / different. AND USE PLACEHOLDERS! ]

        # Notes [optional]

        [optional: edge cases, details, and an area to call or repeat out specific important considerations]
      PROMPT

      messages = [
        { role: "system", content: meta_prompt },
        { role: "user", content: "Task, Goal, or Current Prompt:\n#{task_or_prompt}" }
      ]

      # Use the openai method to create a chat completion
      response = openai(model: "gpt-4o", prompts: messages)

      response
    end
  end
end

