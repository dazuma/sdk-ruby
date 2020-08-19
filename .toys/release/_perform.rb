# frozen_string_literal: true

desc "Perform a full release from Github actions"

long_desc \
  "This tool performs an official release of cloud_events. It is intended to" \
  " be called from within a Github Actions workflow, and may not work if run" \
  " locally, unless the environment is set up as expected."

flag :repo, "--repo=VAL", default: ::ENV["GITHUB_REPOSITORY"]
flag :release_ref, "--release-ref=VAL", default: ::ENV["GITHUB_REF"]
flag :release_sha, "--release-sha=VAL", default: ::ENV["GITHUB_SHA"]
flag :api_key, "--api-key=VAL", default: ::ENV["RUBYGEMS_API_KEY"]
flag :gh_pages_dir, "--gh-pages-dir=VAL", default: "tmp"
flag :user_name, "--user-name=VAL"
flag :user_email, "--user-email=VAL"
flag :enable_releases, "--enable-releases=VAL"

include :exec, exit_on_nonzero_status: true
include :fileutils
include :terminal, styled: true
include "release-tools"

def run
  cd context_directory

  set :user_name, nil if user_name.to_s.empty?
  set :user_email, nil if user_email.to_s.empty?

  gem_name, version = parse_ref release_ref
  logger.info "Releasing cloud_events #{version}..."

  verify_library_version gem_name, version
  verify_changelog_content gem_name, version

  build_gem gem_name, version
  build_docs gem_name, version, gh_pages_dir
  set_default_docs gem_name, version, gh_pages_dir if version =~ /^\d+\.\d+\.\d+$/

  dry_run = /^t/i !~ enable_releases.to_s ? true : false
  setup_git_config gh_pages_dir
  using_api_key api_key do
    push_gem gem_name, version, dry_run: dry_run
    push_docs gem_name, version, gh_pages_dir, dry_run: dry_run
  end
  mark_release_pr_as_completed gem_name
end

def parse_ref ref
  match = %r{^refs/tags/([^/]+)/v(\d+\.\d+\.\d+(?:\.(?:\d+|[a-zA-Z][\w]*))*)$}.match ref
  error "Illegal release ref: #{ref}" unless match
  [match[1], match[2]]
end

def setup_git_config dir
  cd dir do
    exec ["git", "config", "user.email", user_email] if user_email
    exec ["git", "config", "user.name", user_name] if user_name
  end
end

def using_api_key key
  home_dir = ::ENV["HOME"]
  creds_path = "#{home_dir}/.gem/credentials"
  creds_exist = ::File.exist? creds_path
  if creds_exist && !key
    logger.info "Using existing Rubygems credentials"
    yield
    return
  end
  error "API key not provided" unless key
  error "Cannot set API key because #{creds_path} already exists" if creds_exist
  begin
    mkdir_p "#{home_dir}/.gem"
    ::File.open creds_path, "w", 0o600 do |file|
      file.puts "---\n:rubygems_api_key: #{api_key}"
    end
    logger.info "Using provided Rubygems credentials"
    yield
  ensure
    exec ["shred", "-u", creds_path]
  end
end

def mark_release_pr_as_completed gem_name
  logger.info "Looking for release PR ..."
  pr = find_release_prs repo,
                        gem_name:  gem_name,
                        merge_sha: release_sha,
                        label:     release_triggered_label
  if pr
    pr_number = pr["number"]
    logger.info "Updating release PR ##{pr_number} ..."
    update_release_pr repo, pr_number,
                      label: release_complete_label,
                      message: "Release complete!",
                      cur_pr: pr
    logger.info "Done."
  else
    warning "Unable to find a release PR to update."
  end
end
