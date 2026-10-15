# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require "open3"

module Harness
  # The only place the harness starts a subprocess (I3). Commands are argv arrays, never shell strings,
  # and children get exactly the environment the caller passes (unsetenv_others, I5).
  module Exec
    # Outcome of one subprocess.
    # exit_code is nil when the process was killed (timeout or signal).
    Result = Data.define(:argv, :exit_code, :stdout, :stderr, :timed_out, :truncated, :ms) do
      # @return [Boolean] true when the process exited with status 0 and did not time out
      def success?
        !timed_out && exit_code == 0 # exit_code may be nil
      end
    end

    READ_CHUNK = 16_384
    DRAIN_GRACE_SEC = 5

    # Run a command and capture its output.
    #
    # @param argv [Array<String>] executable followed by its arguments
    # @param chdir [String] working directory for the child
    # @param env [Hash{String=>String}] the child's complete environment
    # @param timeout [Numeric] seconds before the process tree is killed
    # @param max_output [Integer] byte cap for each of stdout and stderr
    # @return [Result]
    # @raise [ArgumentError] when argv or env are malformed
    # @raise [CommandNotFoundError] when the executable cannot be started
    def self.run(argv, chdir:, env:, timeout: 600, max_output: 204_800)
      check_argv!(argv)
      check_env!(env)
      started = clock
      opts = { chdir: chdir, unsetenv_others: true }
      opts[:pgroup] = true unless windows?
      # [cmd, argv0] form: Ruby never hands a one-element command to a shell.
      Open3.popen3(env, [argv[0], argv[0]], *argv[1..], **opts) do |stdin, stdout, stderr, waiter|
        stdin.close
        out_reader = drain(stdout, max_output)
        err_reader = drain(stderr, max_output)
        timed_out = waiter.join(timeout).nil?
        kill_tree(waiter.pid) if timed_out
        status = waiter.value
        out, out_cut = finish(out_reader, stdout)
        err, err_cut = finish(err_reader, stderr)
        Result.new(argv: argv.dup.freeze, exit_code: status.exitstatus, stdout: out, stderr: err,
                   timed_out: timed_out, truncated: out_cut || err_cut, ms: ((clock - started) * 1000).round)
      end
    rescue Errno::ENOENT, Errno::EACCES, Errno::ENOEXEC => e
      raise CommandNotFoundError, "cannot run #{argv.first.inspect}: #{e.message}"
    end

    # @return [Boolean] true on Windows
    def self.windows?
      RUBY_PLATFORM.match?(/mswin|mingw|cygwin/)
    end

    # @param argv [Object]
    # @return [void]
    # @raise [ArgumentError]
    def self.check_argv!(argv)
      raise ArgumentError, "argv: expected non-empty array, got #{argv.class}" unless argv.is_a?(Array) && !argv.empty?

      argv.each_with_index do |arg, i|
        raise ArgumentError, "argv[#{i}]: expected string, got #{arg.class}" unless arg.is_a?(String)
        raise ArgumentError, "argv[#{i}]: contains NUL byte" if arg.include?("\0")
      end
      raise ArgumentError, "argv[0]: empty executable name" if argv[0].empty?
    end
    private_class_method :check_argv!

    # @param env [Object]
    # @return [void]
    # @raise [ArgumentError]
    def self.check_env!(env)
      raise ArgumentError, "env: expected hash, got #{env.class}" unless env.is_a?(Hash)

      env.each do |k, v|
        raise ArgumentError, "env: keys and values must be strings (#{k.inspect})" unless k.is_a?(String) && v.is_a?(String)
      end
    end
    private_class_method :check_env!

    # Read an IO to EOF on a thread, keeping at most limit bytes.
    # @param io [IO]
    # @param limit [Integer]
    # @return [Thread] whose value is [String, Boolean truncated]
    def self.drain(io, limit)
      Thread.new do
        buf = String.new(encoding: Encoding::BINARY)
        cut = false
        begin
          loop do
            chunk = io.readpartial(READ_CHUNK)
            room = limit - buf.bytesize
            if chunk.bytesize > room
              buf << chunk.byteslice(0, room) if room.positive?
              cut = true
            else
              buf << chunk
            end
          end
        rescue EOFError, IOError
          nil
        end
        [buf, cut]
      end
    end
    private_class_method :drain

    # Wait for a reader thread; if a grandchild still holds the pipe, close it and move on.
    # @param reader [Thread]
    # @param io [IO]
    # @return [Array(String, Boolean)]
    def self.finish(reader, io)
      io.close if reader.join(DRAIN_GRACE_SEC).nil?
      buf, cut = reader.value
      [buf.force_encoding(Encoding::UTF_8).scrub, cut]
    end
    private_class_method :finish

    # Kill a process and its children.
    # @param pid [Integer]
    # @return [void]
    def self.kill_tree(pid)
      if windows?
        taskkill = File.join(ENV.fetch("SystemRoot", "C:\\Windows"), "System32", "taskkill.exe")
        Open3.popen3({}, [taskkill, taskkill], "/T", "/F", "/PID", pid.to_s) { |_i, _o, _e, w| w.value }
      else
        Process.kill("KILL", -pid)
      end
    rescue Errno::ESRCH, Errno::ENOENT
      nil
    end
    private_class_method :kill_tree

    # @return [Float] monotonic seconds
    def self.clock
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
    private_class_method :clock
  end
end
