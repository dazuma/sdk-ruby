# frozen_string_literal: true

require "json"
require "yaml"
require "toys/utils/exec"

class ReleaseUtils
  def initialize tool_context
    @tool_context = tool_context
    release_info_path = @tool_context.find_data "releases.yml"
    load_release_info release_info_path
    @logger = @tool_context.logger
    @error_proc = nil
  end

  attr_reader :repo_path
  attr_reader :main_branch
  attr_reader :default_gem
  attr_reader :tool_context
  attr_reader :logger

  def all_gems
    @gems.keys
  end

  def gem_info gem_name, key = nil
    info = @gems[gem_name]
    key ? info[key] : info
  end

  def gem_directory gem_name, from: :context
    path = gem_info gem_name, "directory"
    case from
    when :context
      path
    when :absolute
      ::File.expand_path path, @tool_context.context_directory
    else
      raise "Unknown from value: #{from.inspect}"
    end
  end

  def gem_changelog_path gem_name, from: :directory
    path = gem_info gem_name, "changelog_path"
    case from
    when :directory
      path
    when :context
      ::File.expand_path path, gem_directory(gem_name)
    when :absolute
      ::File.expand_path path, gem_directory(gem_name, from: :absolute)
    else
      raise "Unknown from value: #{from.inspect}"
    end
  end

  def gem_version_rb_path gem_name, from: :directory
    path = gem_info gem_name, "version_rb_path"
    case from
    when :directory
      path
    when :context
      ::File.expand_path path, gem_directory(gem_name)
    when :absolute
      ::File.expand_path path, gem_directory(gem_name, from: :absolute)
    else
      raise "Unknown from value: #{from.inspect}"
    end
  end

  def gem_version_constant gem_name
    gem_info gem_name, "version_constant"
  end

  def gem_cd gem_name, &block
    dir = gem_directory gem_name, from: :absolute
    ::Dir.chdir dir, &block
  end

  def release_pending_label
    "release: pending"
  end

  def release_error_label
    "release: error"
  end

  def release_aborted_label
    "release: aborted"
  end

  def release_complete_label
    "release: complete"
  end

  def release_branch_name gem_name
    "release/#{gem_name}"
  end

  def current_sha ref = nil
    capture(["git", "rev-parse", ref || "HEAD"]).strip
  end

  def current_branch
    branch = capture(["git", "branch", "--show-current"]).strip
    branch.empty? ? nil : branch
  end

  def git_remote_url remote
    capture(["git", "remote", "get-url", remote]).strip
  end

  def exec cmd, **opts, &block
    @tool_context.exec cmd, **opts, &block
  end

  def capture cmd, **opts, &block
    @tool_context.capture cmd, **opts, &block
  end

  def find_release_prs gem_name: nil, merge_sha: nil, label: nil
    label ||= release_pending_label
    args = {
      state: merge_sha ? "closed" : "open",
      sort: "updated",
      direction: "desc",
      per_page: 20
    }
    if gem_name
      repo_owner = repo_path.split("/").first
      args[:head] = "#{repo_owner}:#{release_branch_name gem_name}"
      args[:sort] = "created"
    end
    query = args.map { |k, v| "#{k}=#{v}" }.join "&"
    output = capture ["gh", "api", "repos/#{repo_path}/pulls?#{query}",
                      "-H", "Accept: application/vnd.github.v3+json"]
    prs = ::JSON.parse output
    if merge_sha
      prs.find do |pr|
        pr["merged_at"] &&
          pr["merge_commit_sha"] == merge_sha &&
          pr["labels"].any? { |label_info| label_info["name"] == label }
      end
    else
      prs.find_all do |pr|
        pr["labels"].any? { |label_info| label_info["name"] == label }
      end
    end
  end

  def update_release_pr pr_number, label: nil, message: nil, cur_pr: nil
    if label
      cur_pr ||= begin
        output = capture ["gh", "api", "repos/#{repo_path}/pulls/#{pr_number}",
                          "-H", "Accept: application/vnd.github.v3+json"]
        cur_pr = ::JSON.parse(output)["data"]
      end
      cur_labels = cur_pr["labels"].map { |label_info| label_info["name"] }
      cur_labels.reject! { |label| label.start_with? "release: " }
      cur_labels << label
      body = ::JSON.dump({labels: cur_labels})
      exec ["gh", "api", "-XPATCH", "repos/#{repo_path}/issues/#{pr_number}",
            "--input", "-", "-H", "Accept: application/vnd.github.v3+json"],
           in: [:string, body], out: :null
    end
    if message
      body = ::JSON.dump({body: message})
      exec ["gh", "api", "repos/#{repo_path}/issues/#{pr_number}/comments",
            "--input", "-", "-H", "Accept: application/vnd.github.v3+json"],
           in: [:string, body], out: :null
    end
  end

  def current_library_version gem_name
    path = gem_version_rb_path gem_name, from: :absolute
    require path
    const = ::Object
    gem_version_constant(gem_name).each do |name|
      const = const.const_get name
    end
    const
  end

  def verify_library_version gem_name, gem_vers, warn_only: false
    @logger.info "Verifying #{gem_name} version file ..."
    lib_vers = current_library_version gem_name
    if gem_vers == lib_vers
      @logger.info "Version file OK"
    else
      path = gem_version_rb_path gem_name, from: :absolute
      error "Requested version #{gem_vers} doesn't match #{gem_name} library version #{lib_vers}.",
            "Modify #{path} and set VERSION = #{gem_vers.inspect}"
    end
    lib_vers
  end

  def verify_changelog_content gem_name, gem_vers, warn_only: false
    @logger.info "Verifying #{gem_name} changelog content..."
    changelog_path = gem_changelog_path gem_name, from: :context
    today = ::Time.now.strftime "%Y-%m-%d"
    entry = []
    state = :start
    lines = ::File.readlines changelog_path
    lines.each do |line|
      case state
      when :start
        if line =~ /^### v#{::Regexp.escape(gem_vers)} \/ \d\d\d\d-\d\d-\d\d\n$/
          entry << line
          state = :during
        elsif line =~ /^### /
          error "The first changelog entry in #{changelog_path} isn't for version #{gem_vers}.",
                "It should start with:",
                "### v#{gem_vers} / #{today}",
                "But it actually starts with:",
                line,
                warn_only: warn_only
          return ""
        end
      when :during
        if line =~ /^### /
          state = :after
        else
          entry << line
        end
      end
    end
    if entry.empty?
      error "The changelog #{changelog_path} doesn't have any entries.",
            "The first changelog entry should start with:",
            "### v#{gem_vers} / #{today}",
            warn_only: warn_only
    else
      @logger.info "Changelog OK"
    end
    entry.join
  end

  def verify_repo_identity git_remote: "origin", warn_only: false
    @logger.info "Verifying git repo identity ..."
    url = git_remote_url git_remote
    cur_repo = case url
    when %r{^git@github.com:([^/]+/[^/]+)\.git$}
      ::Regexp.last_match(1)
    when %r{^https://github.com/([^/]+/[^/]+)/?$}
      ::Regexp.last_match(1)
    else
      error "Unrecognized remote url: #{url.inspect}"
    end
    if cur_repo == repo_path
      @logger.info "Git repo is correct."
    else
      error "Remmote repo is #{cur_repo}, expected #{repo_path}", warn_only: warn_only
    end
  end

  def verify_git_clean warn_only: false
    @logger.info "Verifying git clean..."
    output = capture(["git", "status", "-s"]).strip
    if output.empty?
      @logger.info "Git working directory is clean."
    else
      error "There are local git changes that are not committed.", warn_only: warn_only
    end
  end

  def verify_github_checks ref: nil, warn_only: false
    @logger.info "Verifying GitHub checks ..."
    ref = current_sha ref
    result = exec ["gh", "api", "repos/#{repo_path}/commits/#{ref}/check-runs",
                   "-H", "Accept: application/vnd.github.antiope-preview+json"],
                  out: :capture, e: false
    unless result.success?
      error "Failed to obtain GitHub check results for #{ref}", warn_only: warn_only
      return
    end
    results = ::JSON.parse result.captured_out
    checks = results["check_runs"]
    error "No GitHub checks found for #{ref}", warn_only: warn_only if checks.empty?
    unless checks.size == results["total_count"]
      error "GitHub check count mismatch for #{ref}", warn_only: warn_only
    end
    ok = true
    checks.each do |check|
      name = check["name"]
      next unless name.start_with? "test"
      unless check["status"] == "completed"
        error "GitHub check #{name.inspect} is not complete", warn_only: warn_only
        ok = false
      end
      unless check["conclusion"] == "success"
        error "GitHub check #{name.inspect} was not successful", warn_only: warn_only
        ok = false
      end
    end
    @logger.info "GitHub checks all passed." if ok
  end

  def error message, *more_messages, warn_only: false
    if warn_only
      warning message
      more_messages.each { |m| waring m }
      return
    end
    if ::ENV["GITHUB_ACTIONS"]
      puts "::error::#{message}"
    else
      @tool_context.puts message, :red, :bold
    end
    more_messages.each { |m| puts(m) }
    if @error_proc
      content = ([message] + more_messages).join "\n"
      @error_proc.call content
    end
    @tool_context.exit 1
  end

  def warning message
    if ::ENV["GITHUB_ACTIONS"]
      puts "::warning::#{message}"
    else
      @logger.warn message
    end
  end

  def on_error &block
    @error_proc = block
  end

  def clear_error_proc
    @error_proc = nil
  end

  private

  def load_release_info file_path
    error "Unable to find releases.yml data file" unless file_path
    info = ::YAML.load_file file_path
    @main_branch = info["main_branch"] || "main"
    @repo_path = info["repo"]
    error "Repo key missing from releases.yml" unless @repo_path
    @gems = {}
    @default_gem = nil
    has_multiple_gems = info["gems"].size > 1
    info["gems"].each do |gem_info|
      name = gem_info["name"]
      error "Name missing from gem in releases.yml" unless name
      gem_info["directory"] ||= has_multiple_gems ? name : "."
      segments = name.split "-"
      name_path = segments.join "/"
      gem_info["version_rb_path"] ||= "lib/#{name_path}/version.rb"
      gem_info["changelog_path"] ||= "CHANGELOG.md"
      gem_info["version_constant"] ||= segments.map { |seg| camelize(seg) } + ["VERSION"]
      gem_info["gh_pages_directory"] ||= has_multiple_gems ? name : "."
      gem_info["gh_pages_version_var"] ||= has_multiple_gems ? "version_#{name}".tr("-", "_") : "version"
      @gems[name] = gem_info
      @default_gem ||= name
    end
    error "Repo key missing from releases.yml" unless @default_gem
  end

  def camelize str
    str.to_s
       .sub(/^_/, "")
       .sub(/_$/, "")
       .gsub(/_+/, "_")
       .gsub(/(?:^|_)([a-zA-Z])/) { ::Regexp.last_match(1).upcase }
  end
end
