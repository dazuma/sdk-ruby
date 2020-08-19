# frozen_string_literal: true

require "json"
require "yaml"

delegate_to ["release", "trigger"]

mixin "release-tools" do
  on_include do
    include :exec, e: true unless include? :exec
    include :fileutils unless include? :fileutils
    include :terminal, styled: true unless include? :terminal
  end

  def load_repo_info
    return if defined? @main_branch
    info = ::YAML.load_file(find_data("releases.yml"))
    @main_branch = info["main_branch"] || "main"
    @repo_path = info["repo"]
    error "Repo key missing from releases.yml" unless @repo_path
    @gems = {}
    @default_gem = nil
    info["gems"].each do |gem_info|
      name = gem_info["name"]
      if name
        gem_info["directory"] ||= "."
        segments = name.split("-")
        gem_info["version_rb_path"] ||= "lib/#{segments.join('/')}/version.rb"
        gem_info["version_constant"] ||= segments.map { |seg| camelize(seg) } + ["VERSION"]
        @gems[name] = gem_info
        @default_gem ||= name
      end
    end
  end

  def camelize str
    str.to_s
       .sub(/^_/, "")
       .sub(/_$/, "")
       .gsub(/_+/, "_")
       .gsub(/(?:^|_)([a-zA-Z])/) { ::Regexp.last_match(1).upcase }
  end

  def repo_path
    load_repo_info
    @repo_path
  end

  def main_branch
    load_repo_info
    @main_branch
  end

  def default_gem
    load_repo_info
    @default_gem
  end

  def all_gems
    load_repo_info
    @gems.keys
  end

  def gem_info gem_name, key = nil
    load_repo_info
    info = @gems[gem_name]
    key ? info[key] : info
  end

  def gem_cd gem_name, &block
    dir = gem_info gem_name, "directory"
    dir = ::File.expand_path dir, context_directory
    cd dir, &block
  end

  def release_pending_label
    "release: pending"
  end

  def release_triggered_label
    "release: triggered"
  end

  def release_error_label
    "release: error"
  end

  def release_abort_label
    "release: aborted"
  end

  def release_complete_label
    "release: complete"
  end

  def release_branch_name gem_name
    "release/#{gem_name}"
  end

  def find_release_prs repo, gem_name: nil, merge_sha: nil, label: nil
    label ||= release_pending_label
    args = {
      state: merge_sha ? "closed" : "open",
      sort: "updated",
      direction: "desc",
      per_page: 10
    }
    if gem_name
      repo_owner = repo_path.split("/").first
      args[:head] = "#{repo_owner}:#{release_branch_name gem_name}"
      args[:sort] = "created"
    end
    query = args.map { |k, v| "#{k}=#{v}" }.join("&")
    output = capture ["gh", "api", "repos/#{repo}/pulls?#{query}",
                      "-H", "Accept: application/vnd.github.v3+json"]
    prs = ::JSON.parse(output)
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

  def update_release_pr repo, pr_number, label: nil, message: nil, cur_pr: nil
    if label
      cur_pr ||= begin
        output = capture ["gh", "api", "repos/#{repo}/pulls/#{pr_number}",
                          "-H", "Accept: application/vnd.github.v3+json"]
        cur_pr = ::JSON.parse(output)["data"]
      end
      cur_labels = cur_pr["labels"].map { |label_info| label_info["name"] }
      cur_labels.reject! { |label| label.start_with? "release: " }
      cur_labels << label
      body = ::JSON.dump({labels: cur_labels})
      exec ["gh", "api", "-XPATCH", "repos/#{repo}/issues/#{pr_number}", "--input", "-",
            "-H", "Accept: application/vnd.github.v3+json"], in: [:string, body], out: :null
    end
    if message
      body = ::JSON.dump({body: message})
      exec ["gh", "api", "repos/#{repo}/issues/#{pr_number}/comments", "--input", "-",
            "-H", "Accept: application/vnd.github.v3+json"], in: [:string, body], out: :null
    end
  end

  def current_library_version gem_name
    info = gem_info gem_name
    dir = ::File.expand_path info["directory"], context_directory
    path = ::File.expand_path info["version_rb_path"], dir
    require path
    const = ::Object
    info["version_constant"].each do |name|
      const = const.const_get(name)
    end
    const
  end

  def verify_library_version gem_name, vers, warn_only: false
    logger.info "Verifying #{gem_name} version..."
    lib_vers = current_library_version gem_name
    unless vers == lib_vers
      info = gem_info gem_name
      path = ::File.join info["directory"], info["version_rb_path"]
      error "Tagged version #{vers} doesn't match #{gem_name} library version #{lib_vers}.",
            "Modify #{path} and set VERSION = #{vers.inspect}"
    end
    vers
  end

  def verify_changelog_content gem_name, vers, warn_only: false
    logger.info "Verifying changelog content..."
    today = ::Time.now.strftime "%Y-%m-%d"
    entry = []
    state = :start
    lines = gem_cd gem_name do
      ::File.readlines "CHANGELOG.md"
    end
    lines.each do |line|
      case state
      when :start
        if line =~ /^### v#{::Regexp.escape(vers)} \/ \d\d\d\d-\d\d-\d\d\n$/
          entry << line
          state = :during
        elsif line =~ /^### /
          error "The first changelog entry isn't for version #{vers}.",
                "It should start with:",
                "### v#{vers} / #{today}",
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
      error "The changelog doesn't have any entries.",
            "The first changelog entry should start with:",
            "### v#{vers} / #{today}",
            warn_only: warn_only
    end
    entry.join
  end

  def verify_repo_identity git_remote: "origin"
    cur_repo = ::ENV["GITHUB_REPOSITORY"] || begin
      url = capture(["git", "remote", "get-url", git_remote]).strip
      case url
      when %r{^git@github.com:([^/]+/[^/]+)\.git$}
        ::Regexp.last_match(1)
      when %r{^https://github.com/([^/]+/[^/]+)/?$}
        ::Regexp.last_match(1)
      else
        error "Unrecognized remote url: #{url.inspect}"
      end
    end

    unless cur_repo == repo_path
      error "Remmote repo is #{cur_repo}, expected #{repo_path}", warn_only: warn_only
    end
  end

  def verify_git_clean warn_only: false
    logger.info "Verifying git clean..."
    output = capture(["git", "status", "-s"]).strip
    unless output.empty?
      error "There are local git changes that are not committed.", warn_only: warn_only
    end
  end

  def verify_github_checks warn_only: false
    logger.info "Verifying GitHub checks..."
    ref = capture(["git", "rev-parse", "HEAD"]).strip
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
    checks.each do |check|
      name = check["name"]
      next unless name.start_with? "test"
      unless check["status"] == "completed"
        error "GitHub check #{name.inspect} is not complete", warn_only: warn_only
      end
      unless check["conclusion"] == "success"
        error "GitHub check #{name.inspect} was not successful", warn_only: warn_only
      end
    end
  end

  def push_github_release commitish, gem_name, gem_version, changelog_content
    body = ::JSON.dump({
      tag_name: "#{gem_name}/v#{gem_version}",
      target_commitish: commitish,
      name: "#{gem_name} #{gem_version}",
      body: changelog_content.strip
    })
    exec ["gh", "api", "repos/#{repo_path}/releases", "--input", "-",
          "-H", "Accept: application/vnd.github.v3+json"], in: [:string, body], out: :null
  end

  def build_gem gem_name, version
    logger.info "Building #{gem_name} #{version} gem..."
    gem_cd gem_name do
      mkdir_p "pkg"
      exec ["gem", "build", "#{gem_name}.gemspec", "-o", "pkg/#{gem_name}-#{version}.gem"]
    end
  end

  def push_gem gem_name, version, dry_run: false
    logger.info "Pushing #{gem_name} #{version} gem..."
    gem_cd gem_name do
      built_file = "pkg/#{gem_name}-#{version}.gem"
      if dry_run
        error "#{built_file} didn't get built." unless ::File.file? built_file
        puts "SUCCESS: Mock release of #{gem_name} #{version}", :green, :bold
      else
        exec ["gem", "push", built_file]
        puts "SUCCESS: Released #{gem_name} #{version}", :green, :bold
      end
    end
  end

  def build_docs gem_name, version, dir
    logger.info "Building #{gem_name} #{version} docs..."
    gem_cd gem_name do
      rm_rf ".yardoc"
      rm_rf "doc"
      exec_separate_tool ["yardoc"]
      dir = "#{dir}/#{gem_name}" unless gem_info gem_name, "toplevel_docs"
      path = "#{dir}/v#{version}"
      rm_rf path
      cp_r "doc", path
    end
  end

  def set_default_docs gem_name, version, dir
    logger.info "Changing default #{gem_name} docs version to #{version}..."
    path = "#{dir}/404.html"
    content = ::IO.read path
    if gem_info gem_name, "toplevel_docs"
      var_name = "version"
    else
      var_name = "version_#{gem_name}".tr "-", "_"
    end
    content.sub!(/#{var_name} = "[\w\.]+";/, "#{var_name} = \"#{version}\";")
    ::File.open path, "w" do |file|
      file.write content
    end
  end

  def push_docs gem_name, version, dir, dry_run: false, git_remote: "origin"
    logger.info "Pushing docs to gh-pages..."
    cd dir do
      exec ["git", "add", "."]
      exec ["git", "commit", "-m", "Generate yardocs for #{gem_name} #{version}"]
      if dry_run
        puts "SUCCESS: Mock docs push for #{gem_name} #{version}.", :green, :bold
      else
        exec ["git", "push", git_remote, "gh-pages"]
        puts "SUCCESS: Pushed docs for #{gem_name} #{version}.", :green, :bold
      end
    end
  end

  def error message, *more_messages, warn_only: false
    if ::ENV["GITHUB_ACTIONS"]
      puts "::error::#{message}"
    else
      puts message, :red, :bold
    end
    more_messages.each { |m| puts(m) }
    exit 1 unless warn_only
  end

  def warning message
    if ::ENV["GITHUB_ACTIONS"]
      puts "::warning::#{message}"
    else
      logger.warn message
    end
  end
end
