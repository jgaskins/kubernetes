require "./spec_helper"
require "../src/kubernetes"

describe "Token Caching and Rotation" do
  it "caches token at initialization and doesn't call proc on every request" do
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

    # Token should have been read once during initialization
    call_count.should eq(1)

    # Verify the cached token is set
    client.@cached_token.should eq("test-token-1")

    # Close the client
    client.close
  end

  it "handles token file read errors gracefully" do
    error_proc = -> {
      raise File::NotFoundError.new("Token file not found", file: "/var/run/secrets/kubernetes.io/serviceaccount/token")
    }

    client = Kubernetes::Client.new(
      server: URI.parse("https://kubernetes.default.svc:443"),
      token: error_proc,
      tls: nil,
    )

    # Token cache should be nil when file read fails
    client.@cached_token.should be_nil

    client.close
  end

  it "uses inotify watcher when token file exists" do
    # Create client
    client = Kubernetes::Client.new(
      server: URI.parse("https://kubernetes.default.svc:443"),
      token: -> { "test-token" },
      tls: nil,
    )

    # If the default service account path exists, watcher should be started
    if File.exists?("/var/run/secrets/kubernetes.io/serviceaccount/token")
      client.@token_file_path.should eq("/var/run/secrets/kubernetes.io/serviceaccount/token")
      client.@token_watcher.should_not be_nil
    else
      # In test environment without SA token, no watcher is started
      client.@token_file_path.should be_nil
      client.@token_watcher.should be_nil
    end

    # Clean up
    client.close
  end
end
