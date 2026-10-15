# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

begin
  require "digest"
rescue LoadError
  # Some Windows application-control policies block digest.so; the pure-Ruby version below is used instead.
  nil
end

module Harness
  # SHA-256 hex digests for cache keys and prompt hashes. Uses Digest when it loads, else pure Ruby (FIPS 180-4).
  module Sha256
    K = [
      0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
      0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
      0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
      0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
      0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
      0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
      0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
      0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
    ].freeze
    H0 = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19].freeze
    MASK = 0xffffffff

    # @param data [String]
    # @return [String] 64 lowercase hex characters
    def self.hex(data)
      defined?(::Digest::SHA256) ? ::Digest::SHA256.hexdigest(data) : pure_hex(data)
    end

    # @param data [String]
    # @return [String] 64 lowercase hex characters, computed without native extensions
    def self.pure_hex(data)
      bytes = data.b
      bit_len = bytes.bytesize * 8
      bytes += "\x80".b
      bytes += "\0".b * ((56 - bytes.bytesize) % 64)
      bytes += [bit_len >> 32, bit_len & MASK].pack("N2")
      h = H0.dup
      bytes.unpack("N*").each_slice(16) { |block| compress(h, block) }
      h.pack("N8").unpack1("H*")
    end

    # @param h [Array<Integer>] the 8 state words, updated in place
    # @param block [Array<Integer>] 16 message words
    # @return [void]
    def self.compress(h, block)
      w = block.dup
      (16...64).each do |i|
        s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
        s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
        w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & MASK
      end
      a, b, c, d, e, f, g, hh = h
      64.times do |i|
        t1 = (hh + (rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)) + ((e & f) ^ (~e & g)) + K[i] + w[i]) & MASK
        t2 = ((rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)) + ((a & b) ^ (a & c) ^ (b & c))) & MASK
        hh = g
        g = f
        f = e
        e = (d + t1) & MASK
        d = c
        c = b
        b = a
        a = (t1 + t2) & MASK
      end
      [a, b, c, d, e, f, g, hh].each_with_index { |v, i| h[i] = (h[i] + v) & MASK }
    end
    private_class_method :compress

    # @return [Integer]
    def self.rotr(x, n)
      ((x >> n) | (x << (32 - n))) & MASK
    end
    private_class_method :rotr
  end
end
