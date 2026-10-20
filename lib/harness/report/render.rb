# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require "json"
require_relative "../state/events"
require_relative "../state/reasons"
require_relative "../state/records"

module Harness
  module Report
    # runs/<runId>/report.md (DESIGN.md 10.2), built only from the run's files: run.json, plan.json, the task
    # folders, the review records, the event log and the model records. Text that came from a model (titles,
    # claims, details) is marked as such and kept on one line, so it cannot add headings or table rows.
    module Render
      TOP_REASONS = 5
      TICK = "\x60"
      MAX_DIAGNOSTICS = 5

      # Write report.md.
      # @param store [State::RunStore]
      # @return [String] the report's path
      def self.write(store)
        path = File.join(store.dir, "report.md")
        File.write("#{path}.tmp", markdown(store), encoding: "UTF-8")
        File.rename("#{path}.tmp", path)
        path
      end

      # @param store [State::RunStore]
      # @return [String]
      def self.markdown(store)
        data = Sources.load(store)
        notes = warnings(data)
        [
          "# Run #{data.run_id}", "",
          *summary(data), "",
          *(notes.empty? ? [] : ["## Read this first", "", *notes, ""]),
          "## Tasks", "", *tasks(data), "",
          "## Gates against the baseline", "", *gates(data), "",
          "## Findings", "", *findings(data), "",
          "## Questions", "", *questions(data), "",
          "## Suspicious text", "", *suspicious(data), "",
          "## Blocked tasks", "", *blocked(data), "",
          "## Rejections", "", *rejections(data), "",
          "## Cost", "", *cost(data), ""
        ].join("\n")
      end

      # Everything the report reads, loaded once.
      class Sources
        attr_reader :run_id, :dir, :run, :plan, :states, :reviews, :final, :summary, :events, :records, :baseline, :integration

        # @param store [State::RunStore]
        # @return [Sources]
        def self.load(store) = new(store)

        # @param store [State::RunStore]
        def initialize(store)
          @run_id = store.run_id
          @dir = store.dir
          @run = store.read_run
          @plan = json(store.plan_path) || {}
          ids = Array(@plan["tasks"]).map { |t| t["id"] }
          @states = ids.to_h { |id| [id, store.read_task_state(id) || { "state" => "pending" }] }
          @reviews = ids.to_h { |id| [id, json(File.join(store.task_dir(id), "review.json"))] }.compact
          @final = json(store.final_review_path)
          @events = State::Events.read(store.events_path)
          @summary = State::Events.fold(@events)
          @records = Dir.glob(File.join(store.records_dir, "*.json")).sort.filter_map { |f| json(f) }
          @baseline = json(store.baseline_path) || {}
          @integration = json(File.join(store.dir, "integration.json")) || []
        end

        # @param id [String]
        # @param name [String]
        # @return [Object, nil]
        def task_file(id, name) = json(File.join(@dir, "tasks", id, name))

        # @return [Hash] the task's last gates-<n>.json, by gate name
        def last_gates(id)
          file = Dir.glob(File.join(@dir, "tasks", id, "gates-*.json")).max_by { |f| f[/gates-(\d+)\.json\z/, 1].to_i }
          Array(file && json(file)).to_h { |g| [g["gate"], g] }
        end

        private

        def json(path)
          State.read_json(path)
        rescue Errno::ENOENT, JSON::ParserError
          nil
        end
      end

      # One line of model or repository text: no newlines, no table pipes, no HTML, bounded length.
      # @param text [Object]
      # @param max [Integer]
      # @return [String]
      def self.line(text, max = 300)
        s = text.to_s.gsub(/\s+/, " ").strip
        s = "#{s[0, max]}…" if s.size > max
        s.gsub("|", "\\|").gsub("<", "&lt;").gsub(">", "&gt;")
      end

      # @return [Array<String>]
      def self.summary(data)
        r = data.run
        t = data.summary["totals"]
        counts = data.states.values.map { |s| s["state"] }.tally
        [
          "- Status: **#{r['status'] || 'unknown'}** (exit code #{r['exitCode'].nil? ? '-' : r['exitCode']})",
          "- Branch: #{code(r['branch'])} from #{code(r['baseSha'].to_s[0, 12])}, worktree #{code(r['worktree'])}",
          "- Stack: #{r['stack'] || '-'}",
          *Array(r["baselineFailing"]).map { |g| "- **Baseline:** #{code(g)} already failed before the run; tasks were judged only on new problems" },
          "- Tasks: #{data.states.size} (#{counts.map { |k, v| "#{v} #{k}" }.join(', ')})",
          "- Model outputs: #{t['produced']} produced, #{t['accepted']} accepted, #{t['rejected']} rejected " \
          "(#{(t['rejectionRate'] * 100).round}% rejected)",
          "- Wall time: #{duration(t['elapsedMs'])}"
        ]
      end

      # What a reader must know before trusting the rest: checks that did not run, review that was cut back, a run
      # that ended early, and changes to what produced the run. Each line says what to do. Empty when there is none.
      # @param data [Sources]
      # @return [Array<String>]
      def self.warnings(data)
        r = data.run
        out = []
        out << "- **Dry run:** no model was called, so nothing was planned or changed." if r["status"] == "dry_run"
        out << "- **Run failed:** #{line(r['error'])}" if r["status"] == "failed" && r["error"]
        out << "- **Stopped early:** the tasks not done yet are listed below; #{code("harness resume #{data.run_id}")} continues the run." if r["status"] == "stopped"
        data.baseline.each do |gate, g|
          next unless g.is_a?(Hash) && g["status"] == "skipped"

          out << "- **Gate not run:** #{code(gate)} could not run (#{line(g['reason'], 160)}), so nothing in this run was " \
                 "checked by it. Install the project's dependencies or fix the gate's command, then run again."
        end
        case r["review"]
        when "off" then out << "- **No review:** review was off (#{code('review: off')}), so only the gates checked these changes."
        when "light"
          out << "- **Light review:** small tasks that passed their gates first time were not reviewed on their own " \
                 "(#{code('review: light')}); the whole run was."
        end
        data.events.each do |e|
          out << "- **Changed mid-run:** #{line(e['detail'], 200)}" if e["subject"] == "identity"
        end
        out
      end

      # @return [Array<String>]
      def self.tasks(data)
        return ["No tasks."] if data.states.empty?

        rows = Array(data.plan["tasks"]).map do |task|
          s = data.states[task["id"]]
          gates = data.last_gates(task["id"]).values.map { |g| "#{g['gate']} #{g['status']}" }.join(", ")
          "| #{task['id']} | #{line(task['title'], 80)} | #{s['state']} | #{s["commit"] ? code(s["commit"][0, 7]) : "-"} | " \
            "#{s['fixRounds'].to_i} | #{gates.empty? ? '-' : gates} |"
        end
        ["Titles are planner output.", "", "| Task | Title | Status | Commit | Fix rounds | Gates |", "| --- | --- | --- | --- | --- | --- |", *rows]
      end

      # @return [Array<String>]
      def self.gates(data)
        names = (data.baseline.keys + data.integration.map { |c| c["gate"] }).uniq.sort
        return ["No gates ran."] if names.empty?

        rows = names.map do |name|
          base = data.baseline[name]
          cmp = data.integration.find { |c| c["gate"] == name }
          reason = cmp&.fetch("reason", nil) || base&.fetch("reason", nil)
          "| #{name} | #{base ? base['status'] : '-'} | #{cmp ? "#{cmp['status']} (#{cmp['verdict']})" : 'not run at integration'} | " \
            "#{reason ? line(reason, 120) : ''} |"
        end
        ["| Gate | Baseline | Integration | Reason |", "| --- | --- | --- | --- |", *rows]
      end

      # Only claims confirmed by a failing test (I8).
      # @return [Array<String>]
      def self.findings(data)
        items = all_reviews(data).flat_map { |where, r| Array(r["findings"]).map { |f| [where, f] } }
        return ["No verified findings."] if items.empty?

        ["Each finding is confirmed by a test that failed while the defect was present.", "",
         *items.map do |where, f|
           "- **#{f['severity']}** #{where} #{code("#{f['file']}:#{f['line']}")}: #{line(f['problem'])} (test #{code(f['test'])})"
         end]
      end

      # Unverified claims and the planner's questions.
      # @return [Array<String>]
      def self.questions(data)
        out = []
        Array(data.run["questions"]).each { |q| out << "- Waiting for an answer: #{line(q)}" }
        Array(data.run["answers"]).each { |q, a| out << "- Answered: #{line(q)} → #{line(a, 120)}" }
        Array(data.plan["questions"]).reject { |q| q["blocking"] }.each { |q| out << "- From the planner: #{line(q['text'])}" }
        all_reviews(data).each do |where, r|
          Array(r["questions"]).each do |c|
            out << "- Unconfirmed claim (#{where}, #{code("#{c['file']}:#{c['line']}")}, #{State::Reasons.text(c['reason'])}): #{line(c['problem'])}"
          end
          # Claims the review's caps stopped before they were checked: listed, so none is silently dropped.
          Array(r["abstained"]).select { |c| Array(c["reasons"]).any? { |x| x.to_s.match?(/maxVerifierCalls|maxRefutedInARow/) } }.each do |c|
            out << "- Not verified (#{where}, #{code("#{c['file']}:#{c['line']}")}, #{line(Array(c['reasons']).first, 120)}): #{line(c['problem'])}"
          end
        end
        out.empty? ? ["None."] : ["Claims here are model output that no test confirmed; they are not findings.", "", *out]
      end

      # Instruction-like text found in repository content during the tasks, and what the review flagged in a change.
      # @return [Array<String>]
      def self.suspicious(data)
        found = data.events.select { |e| e["reason"] == "untrusted.instruction_like" }.map do |e|
          "- #{e['task'] || 'run'}, #{code(e['subject'])}: #{line(e['detail'], 200)}"
        end
        all_reviews(data).each do |where, r|
          Array(r["suspicious"]).each { |q| found << "- Review of #{where}: \"#{line(q, 200)}\"" }
        end
        return ["None found."] if found.empty?

        ["Text in the repository that reads like instructions to a model. The model was told it is data, and the gates " \
         "decided every task; check these files for planted text.", "", *found.uniq]
      end

      # @return [Array<String>]
      def self.blocked(data)
        ids = data.states.select { |_, s| s["state"] == "blocked" }.keys
        return ["None."] if ids.empty?

        ids.flat_map do |id|
          info = data.task_file(id, "blocked.json") || {}
          patch = File.file?(File.join(data.dir, "tasks", id, "blocked.patch")) ? code("tasks/#{id}/blocked.patch") : "no patch"
          diags = Array(info["gates"]).flat_map { |g| Array(g["diagnostics"]).map { |d| [g["gate"], d] } }.first(MAX_DIAGNOSTICS)
          ["- **#{id}**: #{State::Reasons.text(info['reason'] || data.states[id]['reason'])}. Patch: #{patch}.",
           *diags.map { |gate, d| "  - #{gate}: #{code("#{d['file']}#{d['line'] ? ":#{d['line']}" : ''}")} #{line(d['message'], 200)}" }]
        end
      end

      # @return [Array<String>]
      def self.rejections(data)
        reasons = data.summary["reasons"].sort_by { |reason, n| [-n, reason] }
        return ["Nothing was rejected."] if reasons.empty?

        stage_of = data.events.select { |e| e["kind"] == "rejected" && e["reason"] }.to_h { |e| [e["reason"], e["stage"]] }
        rows = reasons.map { |reason, n| "| #{n} | #{State::Reasons.text(reason)} | #{code(reason)} | #{stage_of[reason]} |" }
        quotes = reasons.first(TOP_REASONS).filter_map do |reason, _|
          e = data.events.find { |x| x["kind"] == "rejected" && x["reason"] == reason && x["detail"] }
          "- #{code(reason)}#{e['task'] ? " (#{e['task']})" : ''}: \"#{line(e['detail'], 200)}\"" if e
        end
        ["| Count | Reason | Code | Stage |", "| --- | --- | --- | --- |", *rows, "",
         "Examples of the most frequent reasons:", "", *quotes]
      end

      # @return [Array<String>]
      def self.cost(data)
        return ["No model calls were recorded."] if data.records.empty?

        groups = data.records.group_by { |r| [r["role"], r["profile"]] }
        rows = groups.sort.map do |(role, profile), recs|
          tin = recs.sum { |r| r.dig("usage", "in").to_i }
          tout = recs.sum { |r| r.dig("usage", "out").to_i }
          known = recs.map { |r| r.dig("usage", "thinking") }.compact
          thinking = known.empty? ? "-" : known.sum.to_s
          "| #{role} | #{profile} | #{recs.size} | #{tin} | #{tout} | #{thinking} | #{duration(recs.sum { |r| r['ms'].to_i })} |"
        end
        models = data.records.map { |r| r["model"] }.compact.uniq.sort
        ["| Role | Profile | Calls | Tokens in | Tokens out | Of which thinking | Time |",
         "| --- | --- | --- | --- | --- | --- | --- |", *rows, "",
         "Models: #{models.empty? ? 'unknown' : models.map { |m| code(line(m, 80)) }.join(', ')}",
         "", "Counts are the server's where it sends them, otherwise estimates. A reply cut off at the length limit " \
             "counts its whole output allowance. Thinking shows - when the server does not report it."]
      end

      # @return [Array<Array(String, Hash)>] ["T1", review] pairs and ["the whole run", final review]
      def self.all_reviews(data)
        data.reviews.map { |id, r| [id, r] } + (data.final ? [["the whole run", data.final]] : [])
      end

      # An inline code span, for paths, shas and codes (TICK is the backtick, written as an escape).
      # @param text [Object]
      # @return [String]
      def self.code(text) = "#{TICK}#{text.to_s.delete(TICK)}#{TICK}"

      # @param ms [Integer, nil]
      # @return [String] e.g. "12m 40s"
      def self.duration(ms)
        s = (ms.to_i / 1000.0).round
        return "#{s}s" if s < 60

        h, rest = s.divmod(3600)
        m, s = rest.divmod(60)
        h.positive? ? "#{h}h #{m}m" : "#{m}m #{s}s"
      end
      private_class_method :summary, :tasks, :gates, :findings, :questions, :suspicious, :blocked, :rejections, :cost, :all_reviews
    end
  end
end
