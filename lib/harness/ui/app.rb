# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require "json"
require_relative "../config"
require_relative "../errors"
require_relative "../model/http"
require_relative "../model/probe"
require_relative "../model/stream"
require_relative "../projects"
require_relative "../providers/actions"
require_relative "../providers/detect"
require_relative "../providers/setup"
require_relative "../state/reasons"
require_relative "builds"
require_relative "chats"
require_relative "conversation"
require_relative "http"

module Harness
  module UI
    # The app's routes (DESIGN.md 11.3). The server has already checked Host, token and Origin (I15). Every action
    # here follows a user's click or keypress in the browser; nothing a model writes can start one. There is no
    # route that runs an arbitrary command: provider actions are the fixed list in Providers::Actions.
    class App
      PUBLIC = File.expand_path("public", __dir__)
      STATIC = { "/app.css" => ["app.css", "text/css; charset=utf-8"], "/app.js" => ["app.js", "text/javascript; charset=utf-8"],
                 "/fonts/InterVariable.woff2" => ["fonts/InterVariable.woff2", "font/woff2"],
                 "/fonts/InterVariable-Italic.woff2" => ["fonts/InterVariable-Italic.woff2", "font/woff2"],
                 "/fonts/OFL.txt" => ["fonts/OFL.txt", "text/plain; charset=utf-8"] }.freeze
      MODES = %w[chat build].freeze

      # @param config_path [String] config.json; chats/, runs/ and .cache/ live next to it
      # @param token [String] embedded in the page for POST requests
      # @param env [Hash{String=>String}]
      # @param pipeline_for [#call] (config, home) -> Pipeline
      # @param http [Model::Http]
      # @param clis [Hash{String=>Array<String>}] provider CLIs to use instead of looking (tests)
      # @param urls [Hash{String=>String}] provider URLs to use instead of the defaults (tests)
      def initialize(config_path:, token:, env:, pipeline_for:, http: Model::Http.new, clis: {}, urls: {})
        @config_path = File.expand_path(config_path)
        @home = File.dirname(@config_path)
        @token = token
        @env = env
        @http = http
        @clis = clis
        @urls = urls
        @pipeline_for = pipeline_for
        @chats = Chats.new(File.join(@home, "chats"))
        @builds = Builds.new(runs_dir: File.join(@home, "runs"), pipeline: -> { @pipeline_for.call(config!, @home) })
        load_config
      end

      # @param req [Request]
      # @return [Response]
      def call(req)
        route(req)
      rescue ConfigError, ParseError, GitError => e
        Response.error(e.is_a?(ConfigError) && e.message.start_with?("no ") ? 404 : 400, e.message)
      rescue ModelUnavailableError => e
        Response.error(503, e.message)
      end

      private

      ROUTES = [
        ["GET", %r{\A/\z}, :index], ["GET", %r{\A/api/state\z}, :state], ["GET", %r{\A/api/chats\z}, :chat_list],
        ["POST", %r{\A/api/chats\z}, :chat_create], ["GET", %r{\A/api/chats/([\w-]+)\z}, :chat_get],
        ["POST", %r{\A/api/chats/([\w-]+)/(rename|delete|model|send)\z}, :chat_action],
        ["GET", %r{\A/api/streams/(\h{16})\z}, :stream], ["POST", %r{\A/api/streams/(\h{16})/stop\z}, :stream_stop],
        ["GET", %r{\A/api/runs/([\w-]+)/events\z}, :run_events], ["GET", %r{\A/api/runs/([\w-]+)/report\z}, :run_report],
        ["POST", %r{\A/api/runs/([\w-]+)/answer\z}, :run_answer], ["POST", %r{\A/api/runs/([\w-]+)/stop\z}, :run_stop],
        ["GET", %r{\A/api/providers\z}, :providers],
        ["POST", %r{\A/api/providers/(custom|action|use)\z}, :provider_post], ["GET", %r{\A/api/projects\z}, :projects],
        ["POST", %r{\A/api/projects/(validate|link|unlink|clone|create)\z}, :project_post]
      ].freeze

      # @return [Response]
      def route(req)
        return static(*STATIC[req.path]) if req.method == "GET" && STATIC.key?(req.path)

        ROUTES.each do |method, pattern, handler|
          next unless req.method == method && (m = pattern.match(req.path))

          return dispatch(handler, req, m.captures)
        end
        Response.error(404, "not found")
      end

      # A fixed table of handlers; no name ever comes from the request.
      # @return [Response]
      def dispatch(handler, req, args)
        case handler
        when :index then index
        when :state then Response.json(state)
        when :chat_list then Response.json(@chats.list)
        when :chat_create then Response.json(@chats.create(model: model_choice(body(req)["model"])))
        when :chat_get then Response.json(@chats.get(args[0]))
        when :chat_action then chat_action(args[0], args[1], body(req))
        when :stream
          Response.sse { |sse| @conversation ? @conversation.run(args[0], sse) : sse.event("error", { "error" => "no model is set up" }) }
        when :stream_stop then Response.json({ "stopped" => @conversation&.stop(args[0]) || false })
        when :run_events
          after = req.query["after"].to_s.match?(/\A\d{1,9}\z/) ? req.query["after"].to_i : 0
          Response.sse { |sse| @builds.events(args[0], after, sse) }
        when :run_report then Response.text(@builds.report(args[0]), type: "text/markdown; charset=utf-8")
        when :run_answer
          @builds.answer(args[0], body(req)["answers"])
          Response.json({ "ok" => true })
        when :run_stop then Response.json({ "stopping" => @builds.stop(args[0]) })
        when :providers then Response.json(Providers::Detect.local(http: @http, env: @env, clis: @clis, urls: @urls).map(&:to_json_hash))
        when :provider_post then provider_post(args[0], body(req))
        when :projects then Response.json(projects!.list.map { |p| project_json(p) })
        when :project_post then project_post(args[0], body(req))
        end
      end

      # @return [Hash] a project for the picker: its name, a short path and its status, never a raw absolute path
      def project_json(project)
        s = projects!.status(project.path, name: project.name)
        s.to_json_hash.merge("linked" => project.linked)
      end

      # Clone and create download and install code: they run only with "confirm": true, which the page sends after
      # the user accepted a dialog showing the exact command. Without it the answer is that command (409).
      # @return [Response]
      def project_post(what, data)
        case what
        when "validate" then Response.json(projects!.status(data["path"]).to_json_hash)
        when "link" then Response.json(project_json(projects!.link(data["path"])))
        when "unlink"
          projects!.unlink(data["name"].to_s)
          load_config
          Response.json({ "ok" => true })
        when "clone", "create"
          plan = what == "clone" ? projects!.clone_plan(data["url"], data["name"]) : projects!.create_plan(data["name"].to_s)
          return Response.json({ "confirm" => plan.to_h.transform_keys(&:to_s) }, status: 409) unless data["confirm"] == true

          project = what == "clone" ? projects!.clone(data["url"], data["name"]) : projects!.create_astro(data["name"].to_s)
          load_config
          Response.json(project_json(project))
        end
      end

      # @return [Projects]
      def projects!
        @projects || raise(ConfigError, "set up a model provider first (Settings)")
      end

      # @return [Response]
      def provider_post(what, data)
        case what
        when "custom" then Response.json(custom(data).to_json_hash)
        when "action" then Response.json(provider_action(data))
        else Response.json(use_provider(data))
        end
      end

      def index
        html = File.read(File.join(PUBLIC, "index.html"), encoding: "UTF-8").sub("{{TOKEN}}", @token)
        Response.text(html, type: "text/html; charset=utf-8")
      end

      def static(file, type)
        Response.new(status: 200, headers: { "Content-Type" => type, "Cache-Control" => "no-cache" },
                     body: File.binread(File.join(PUBLIC, file)), stream: nil)
      end

      # @return [Hash]
      def state
        { "configured" => !@config.nil?, "configPath" => @config_path, "chats" => @chats.list,
          "models" => @conversation ? @conversation.models : [], "reasons" => State::Reasons::TEXT }
      end

      # @return [Response]
      def chat_action(id, action, data)
        case action
        when "rename" then Response.json(@chats.rename(id, data["title"]))
        when "delete"
          @chats.delete(id)
          Response.json({ "deleted" => id })
        when "model"
          choice = model_choice(data) or raise ParseError, "choose a configured model"
          chat = @chats.update(id) do |c|
            switched = c["model"] && c["model"] != choice && !c["messages"].empty?
            c["model"] = choice
            c["messages"] << { "role" => "note", "content" => "Model switched to #{choice['profile']} · #{choice['model']}" } if switched
          end
          Response.json(chat)
        else send_message(id, data)
        end
      end

      # @return [Response]
      def send_message(id, data)
        text = data["text"].to_s
        mode = MODES.include?(data["mode"]) ? data["mode"] : "chat"
        raise ParseError, "the message is empty" if text.strip.empty?

        config!
        @chats.get(id)
        if mode == "build"
          project = projects!.find(data["project"].to_s)
          status = projects!.status(project.path, name: project.name)
          raise ParseError, "#{project.name}: #{status.error}" if status.error

          run = @builds.start(request: text, repo: project.path)
          @chats.append(id, { "role" => "user", "content" => text, "mode" => "build" })
          @chats.append(id, { "role" => "build", "runId" => run, "project" => project.name })
          Response.json({ "run" => run })
        else
          @chats.append(id, { "role" => "user", "content" => text, "mode" => "chat" })
          Response.json({ "stream" => @conversation.prepare(id) })
        end
      end

      # @return [Hash, nil] {"profile", "model"} when the profile is configured
      def model_choice(data)
        return nil unless data.is_a?(Hash) && @config&.profiles&.key?(data["profile"]) && data["model"].is_a?(String)
        return nil unless data["model"].match?(Providers::Actions::MODEL)

        { "profile" => data["profile"], "model" => data["model"] }
      end

      # @return [Providers::Provider]
      def custom(data)
        url = data["baseUrl"].to_s.strip.chomp("/")
        raise ParseError, "an http(s) URL such as http://127.0.0.1:8080/v1" unless url.match?(%r{\Ahttps?://[\w.:\[\]-]+(?:/[\w./-]*)?\z})

        key_env = data["keyEnv"].to_s
        raise ParseError, "give the name of an env var, not a key" unless key_env.empty? || key_env.match?(Providers::Setup::KEY_ENV)

        Providers::Detect.custom(http: @http, base_url: url, key: key_env.empty? ? nil : @env[key_env])
      end

      # @return [Hash]
      def provider_action(data)
        provider = Providers::Detect.local(http: @http, env: @env, clis: @clis, urls: @urls).find { |p| p.kind == data["kind"] }
        raise ParseError, "#{data['kind'].to_s[0, 20]} was not found on this machine" unless provider&.cli

        outcome = Providers::Actions.run(cli: provider.cli, kind: provider.kind, action: data["action"].to_s, model: data["model"],
                                         env: @env, chdir: @home)
        result = { "ok" => outcome.ok, "output" => outcome.output }
        result["models"] = Providers::Actions.lms_models(outcome.output) if provider.kind == "lmstudio" && data["action"] == "ls"
        result
      end

      # @return [Hash] the probe results, in plain words too
      def use_provider(data)
        kind = data["kind"].to_s
        base = { "lmstudio" => @urls.fetch("lmstudio", Providers::Detect::LMSTUDIO_URL),
                 "ollama" => "#{@urls.fetch('ollama', Providers::Detect::OLLAMA_URL)}/v1" }[kind] || data["baseUrl"].to_s
        name = kind.match?(/\A(?:lmstudio|ollama|custom)\z/) ? kind : "custom"
        model = data["model"].to_s
        raise ParseError, "choose a model" unless model.match?(Providers::Actions::MODEL)

        key_env = data["keyEnv"].to_s.empty? ? nil : data["keyEnv"].to_s
        Providers::Setup.use(path: @config_path, name: name, base_url: custom_url(name, base), model: model, key_env: key_env)
        load_config
        caps = @probe.call(@config.profiles[name], refresh: true)
        { "profile" => name, "model" => caps.model_id, "summary" => plain_words(caps) }
      end

      def custom_url(name, base)
        return base unless name == "custom"
        raise ParseError, "an http(s) URL" unless base.match?(%r{\Ahttps?://})

        base
      end

      # e.g. "16K context, JSON mode: yes, tools: no, thinking can be turned off"
      # @return [String]
      def plain_words(caps)
        ctx = caps.context_tokens >= 1024 ? "#{(caps.context_tokens / 1024.0).round}K" : caps.context_tokens.to_s
        json = caps.structured_output == "prompt" ? "no" : "yes"
        tools = caps.tool_calls == "native" ? "yes" : "no"
        thinking = caps.thinking_control == "none" ? "thinking cannot be turned off" : "thinking can be turned off"
        "#{ctx} context, JSON mode: #{json}, tools: #{tools}, #{thinking}"
      end

      # @return [void]
      def load_config
        @config = File.file?(@config_path) ? Config.load(@config_path, env: @env) : nil
        @probe = Model::Probe.new(http: @http, cache_dir: File.join(@home, ".cache"), env: @env)
        @projects = @config && Projects.new(home: @home, config_path: @config_path, config: @config, env: @env)
        @conversation = @config && Conversation.new(config: @config, chats: @chats, probe: @probe, stream: Model::Stream.new(env: @env),
                                                    http: @http, env: @env)
      end

      # @return [Config]
      # @raise [ConfigError]
      def config!
        @config || raise(ConfigError, "set up a model provider first (Settings)")
      end

      # @return [Hash]
      def body(req)
        data = req.json
        raise ParseError, "expected a JSON object" unless data.is_a?(Hash)

        data
      end
    end
  end
end
