# frozen_string_literal: true

desc "Perform a full release from Github actions"

long_desc \
  "This tool performs an official gem release. It is intended to be called" \
  " from within a Github Actions workflow, and may not work if run locally," \
  " unless the environment is set up as expected."

required_arg :gem_name
required_arg :gem_version

flag :only, "--only=VAL", accept: ["precheck", "gem", "docs", "github-release"]
flag :skip_checks
flag :enable_releases, "--enable-releases[=VAL]"
flag :gh_pages_dir, "--gh-pages-dir=VAL"
flag :git_remote, "--git-remote=VAL", default: "origin"
flag :git_user_email, "--git-user-email=VAL"
flag :git_user_name, "--git-user-name=VAL"
flag :github_sha, "--github-sha=VAL"
flag :rubygems_api_key, "--rubygems-api-key=VAL"

include :exec, exit_on_nonzero_status: true
include :fileutils
include :terminal, styled: true

def run
  require "release_utils"
  require "release_perform"

  cd context_directory
  utils = ReleaseUtils.new self

  unless ::ENV["GITHUB_ACTIONS"]
    unless confirm "Perform a release locally, outside the normal process? ", :bold, :red
      utils.error "Release aborted"
    end
  end

  [:gh_pages_dir, :git_user_email, :git_user_name, :rubygems_api_key].each do |key|
    set key, nil if get(key).to_s.empty?
  end
  set :github_sha, utils.current_sha if github_sha.to_s.empty?
  dry_run = /^t/i =~ enable_releases.to_s ? false : true

  docs_builder_tool = utils.gem_info gem_name, "docs_builder_tool"
  docs_builder = docs_builder_tool ? proc { exec_separate_tool Array(docs_builder_tool) } : nil

  performer = ReleasePerform.new utils,
                                 release_sha: github_sha,
                                 skip_checks: skip_checks,
                                 rubygems_api_key: rubygems_api_key,
                                 git_remote: git_remote,
                                 git_user_name: git_user_name,
                                 git_user_email: git_user_email,
                                 gh_pages_dir: gh_pages_dir,
                                 docs_builder: docs_builder,
                                 dry_run: dry_run
  instance = performer.instance gem_name, gem_version
  instance.perform only: only
end
