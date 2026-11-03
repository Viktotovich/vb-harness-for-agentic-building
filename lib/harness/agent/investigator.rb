# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require_relative "../prompts"
require_relative "../untrusted"
require_relative "session"

module Harness
  module Agent
    # Before planning in agent mode: an agent that can read, search and run the project's checks, but not change
    # files, explores the repository for the request. Its findings go to the planner as model output (fenced, I9),
    # so plans start from the code as it is: where things live, the conventions, and for a bug, where it comes from.
    module Investigator
      FILE = "investigation.md"

      # @param client [Model::Client]
      # @param config [Config]
      # @param setup [Run::Setup]
      # @param request [String]
      # @return [String, nil] the findings, or nil when the agent found nothing to hand in
      def self.call(client:, config:, setup:, request:)
        saved = File.join(setup.store.dir, FILE)
        return File.read(saved, encoding: "UTF-8") if File.file?(saved)

        settings = config.agent
        toolbox = Toolbox.new(root: setup.worktree.root, protected: setup.stack.protected_paths, stack: setup.stack,
                              settings: settings, runner: setup.runner, worktree: setup.worktree, writable: false)
        system = Prompts.render("agent_investigate_system", checks: setup.stack.gates.keys.join(", "))
        events = setup.events
        events.emit(stage: "map", kind: "stage_started", subject: "investigation")
        on_step = lambda do |kind, d|
          next unless kind == :tool

          if d[:ok] then events.emit(stage: "map", kind: "accepted", subject: "#{d[:tool]}: #{d[:outcome]}"[0, 160])
          else events.emit(stage: "map", kind: "rejected", subject: d[:tool].to_s[0, 40], reason: "agent.tool_error", detail: d[:outcome].to_s[0, 300])
          end
        end
        session = Session.new(client: client, role: :planner, system: system, toolbox: toolbox, label: "investigate", on_step: on_step)
        result = session.run(Prompts.render("agent_investigate_user", request: request), max_steps: settings.max_investigate_steps)
        findings = result.finished || result.text.to_s.strip
        events.emit(stage: "map", kind: "stage_finished", subject: "investigation",
                    detail: "#{session.steps} tool calls#{result.finished ? '' : ', stopped without finishing'}")
        return nil if findings.empty?

        File.write(saved, findings, encoding: "UTF-8")
        findings
      rescue ModelOutputError, ContextOverflowError => e
        setup.events.emit(stage: "map", kind: "rejected", subject: "investigation", reason: e.respond_to?(:reason) ? e.reason : "model.context_overflow",
                          detail: e.message[0, 300])
        nil
      end
    end
  end
end
