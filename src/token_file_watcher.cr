{% if flag?(:linux) %}
  require "inotify"

  module Kubernetes
    # Watches a token file for changes using inotify (Linux only).
    # Caches the token in memory and reloads it when Kubernetes rotates
    # the projected service account token.
    #
    # Kubernetes uses an atomic symlink swap for token rotation:
    # 1. Creates new timestamped directory with updated token
    # 2. Uses MOVED_TO to swap ..data symlink to new directory
    # 3. Deletes old directory
    #
    # We watch the parent directory for MOVED_TO events on ..data to catch rotation.
    class TokenFileWatcher
      @token : String
      @mutex : Mutex = Mutex.new
      @watcher : Inotify::Watcher?
      @closed : Bool = false
      @log : Log

      def initialize(@token_file : Path, @log = Log.for("kubernetes.token_watcher"))
        @token = read_token
        @watcher = start_watcher
      end

      def closed? : Bool
        @mutex.synchronize { @closed }
      end

      def token : String
        @mutex.synchronize { @token }
      end

      def close : Nil
        @mutex.synchronize do
          return if @closed
          @closed = true
          @watcher.try(&.close)
        end
      end

      private def read_token : String
        File.read(@token_file.to_s).strip
      rescue ex : File::NotFoundError | File::Error
        @log.warn { "Failed to read token file #{@token_file}: #{ex.message}" }
        ""
      end

      private def reload_token(reason : String) : Nil
        @mutex.synchronize do
          @log.info { "#{reason}, reloading token" }
          @token = read_token
        end
      end

      private def start_watcher : Inotify::Watcher?
        return nil unless File.exists?(@token_file.to_s)

        parent_dir = File.dirname(@token_file.to_s)
        token_basename = File.basename(@token_file.to_s)

        watcher = Inotify.watch(parent_dir) do |event|
          next if @mutex.synchronize { @closed }

          if event.type.moved_to? && event.name == "..data"
            reload_token("Token rotated (#{event.type} #{event.name})")
          elsif event.name == token_basename && (event.type.modify? || event.type.close_write?)
            reload_token("Token file changed (#{event.type})")
          end
        end

        @log.info { "Started inotify watcher for token directory: #{parent_dir}" }
        watcher
      rescue ex
        @log.warn { "Failed to start token file watcher: #{ex.message}" }
        nil
      end
    end
  end
{% end %}
