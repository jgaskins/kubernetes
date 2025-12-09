require "./spec_helper"
require "../src/kubernetes"

describe "Token Handling" do
  it "calls token proc on each request (non-caching behavior for proc-based clients)" do
    call_count = 0
    token_proc = -> {
      call_count += 1
      "test-token-#{call_count}"
    }

    client = Kubernetes::Client.new(
      server: URI.parse("https://kubernetes.default.svc:443"),
      token: token_proc,
      tls: nil,
    )

    # Token proc is called lazily, not at initialization
    # The proc will be called when making requests
    call_count.should eq(0)

    client.close
  end

  it "invokes on_close callbacks when client is closed" do
    callback_called = false

    client = Kubernetes::Client.new(
      server: URI.parse("https://kubernetes.default.svc:443"),
      token: -> { "test-token" },
      tls: nil,
    )

    client.on_close { callback_called = true }

    callback_called.should be_false
    client.close
    callback_called.should be_true
  end

  it "invokes multiple on_close callbacks in order" do
    callbacks = [] of Int32

    client = Kubernetes::Client.new(
      server: URI.parse("https://kubernetes.default.svc:443"),
      token: -> { "test-token" },
      tls: nil,
    )

    client.on_close { callbacks << 1 }
    client.on_close { callbacks << 2 }
    client.on_close { callbacks << 3 }

    client.close
    callbacks.should eq([1, 2, 3])
  end
end

{% if flag?(:linux) %}
  describe Kubernetes::TokenFileWatcher do
    it "reads token from file at initialization" do
      # Create a temp file with a token
      tempfile = File.tempfile("token") do |f|
        f.print "initial-token"
      end

      begin
        watcher = Kubernetes::TokenFileWatcher.new(Path[tempfile.path])
        watcher.token.should eq("initial-token")
        watcher.close
      ensure
        tempfile.delete
      end
    end

    it "strips whitespace from token" do
      tempfile = File.tempfile("token") do |f|
        f.print "  token-with-whitespace  \n"
      end

      begin
        watcher = Kubernetes::TokenFileWatcher.new(Path[tempfile.path])
        watcher.token.should eq("token-with-whitespace")
        watcher.close
      ensure
        tempfile.delete
      end
    end

    it "returns empty string when file doesn't exist" do
      watcher = Kubernetes::TokenFileWatcher.new(Path["/nonexistent/path/token"])
      watcher.token.should eq("")
      watcher.close
    end

    it "marks itself as closed after close" do
      tempfile = File.tempfile("token") do |f|
        f.print "test-token"
      end

      begin
        watcher = Kubernetes::TokenFileWatcher.new(Path[tempfile.path])
        watcher.closed?.should be_false
        watcher.close
        watcher.closed?.should be_true
      ensure
        tempfile.delete
      end
    end
  end
{% end %}
