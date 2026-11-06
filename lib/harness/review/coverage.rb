# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require_relative "../errors"
require_relative "../model/client"
require_relative "../prompts"
require_relative "../untrusted"
require_relative "findings"
require_relative "prompt_check"

module Harness
  module Review
    # What a change was asked to do. task: this task's plan text, nil for the whole run; others: the plan's other
    # tasks, which own the rest of the request.
    Scope = Data.define(:request, :task, :others)
    # One thing the request asks for. status: met, missing or elsewhere (another task owns it).
    RequestItem = Data.define(:requirement, :status, :file, :why)

    # The check against the request: one reply that goes through the request item by item. Discovery never sees the
    # request, and in a field eval four changes that left out something the request asked for got empty reviews.
    # A gap goes straight to the confirming test, without the verifier: a test that fails is its proof (I8), and a
    # gap is often code that isn't there, which has no line for the verifier to check.
    class Coverage
      STATUSES = %w[met missing elsewhere].freeze
      FIELDS = %w[requirement status file why].freeze
      MAX_ITEMS = 20
      RUN = "request-check"
      SCHEMA = {
        "type" => "object", "required" => ["items"],
        "properties" => {
          "items" => { "type" => "array", "maxItems" => MAX_ITEMS, "items" => {
            "type" => "object", "required" => FIELDS,
            "properties" => FIELDS.to_h { |f| [f, { "type" => "string" }] }.merge("status" => { "type" => "string", "enum" => STATUSES })
          } }
        }
      }.freeze

      # A client parser.
      # @param obj [Object] the reply's JSON value
      # @return [Array<RequestItem>]
      # @raise [ParseError] when it is not an object with items, or an item has an unknown status
      def self.parse(obj)
        raise ParseError, "the request check reply is not a JSON object with items" unless obj.is_a?(Hash) && obj["items"].is_a?(Array)

        obj["items"].first(MAX_ITEMS).map do |item|
          raise ParseError, "each item must be an object" unless item.is_a?(Hash)
          raise ParseError, "status must be one of #{STATUSES.join(', ')}" unless STATUSES.include?(item["status"])

          RequestItem.new(requirement: item["requirement"].to_s[0, 300], status: item["status"], file: item["file"].to_s[0, 300],
                          why: item["why"].to_s[0, 300])
        end
      end

      # @param ctx [Context]
      def initialize(ctx)
        @ctx = ctx
      end

      # @param scope [Scope]
      # @param prepared [Prepared] the diff, as discovery saw it
      # @param subject [String] e.g. "task T1"
      # @param failures [Array<String>] gets a line when the check could not run
      # @return [Array<Claim>] accepted claims, one for each gap
      # @raise [ModelUnavailableError]
      def call(scope, prepared, subject, failures)
        # A gap read from part of a diff could be in the part not shown.
        if prepared.chunks.size != 1
          @ctx.emit("review.discover", "skipped", subject: RUN, detail: "the diff is in #{prepared.chunks.size} parts, so the check would not see all of it")
          return []
        end

        chunk = prepared.chunks.first
        system = Prompts.render("review_request_system")
        user = Prompts.render("review_request_user", framework: @ctx.framework.line, request: Untrusted.fence(scope.request),
                                                     task: scope.task && Untrusted.fence(scope.task),
                                                     others: scope.others.empty? ? nil : Untrusted.fence(scope.others.join("\n")),
                                                     subject: subject, notes: @ctx.notes, diff: Untrusted.fence(chunk.text))
        problems = PromptCheck.problems("request", system: system, user: user, files: chunk.files.map(&:path))
        return failed("prompt check failed: #{problems.join('; ')}", "claim.failed_checks", failures) unless problems.empty?

        @ctx.emit("review.discover", "stage_started", subject: RUN)
        items = @ctx.client.complete(:reviewer, Model::Messages.new(system: system, user: user), label: "#{@ctx.label}.request",
                                                                                                 schema: SCHEMA, parser: self.class.method(:parse)).value
        gaps = items.select { |i| i.status == "missing" }
        @ctx.emit("review.discover", "stage_finished", subject: RUN, detail: "#{items.size} items, #{gaps.size} missing")
        gaps.each_with_index.map { |gap, i| claim("G#{i + 1}", gap, chunk.files) }
      rescue ModelOutputError => e
        failed(e.message[0, 200], e.reason, failures)
      rescue ContextOverflowError => e
        failed(e.message[0, 200], "model.context_overflow", failures)
      end

      private

      # @return [Array] empty: the review goes on without this check
      def failed(message, reason, failures)
        failures << "#{RUN}: #{message}"
        @ctx.emit("review.discover", "rejected", subject: RUN, reason: reason, detail: message[0, 300])
        []
      end

      # The file the model names, or the first one in the diff: what is missing may belong in a file not shown.
      # @return [Claim]
      def claim(id, gap, files)
        file = files.find { |f| f.path == gap.file } || files.first
        added = file.code.find { |l| l.kind == "+" }
        problem = "The request asks for this and the change does not do it: #{gap.requirement} #{gap.why}".strip
        finding = Finding.new(file: file.path, line: added&.new_line || 1, severity: "high", confidence: "medium", problem: problem,
                              evidence: added&.text.to_s, mechanism: gap.why, preconditions: "", expected_actual: gap.requirement,
                              unverified: "", found_by: [RUN], on_added_line: !added.nil?)
        Claim.new(id: id, finding: finding, outcome: "accept", reason: "request.gap", reasons: [gap.why], severity: "high",
                  verdict: nil, citations: [], excerpt: nil)
      end
    end
  end
end
