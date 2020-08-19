# frozen_string_literal: true

desc "Builds and releases the gem from the local checkout"

required_arg :gem_name
required_arg :version

flag :git_remote, "--git-remote=VAL", default: "origin"
flag :dry_run, "--[no-]dry-run", default: false

include :exec, exit_on_nonzero_status: true
include :fileutils
include :terminal
include "release-tools"

def run
  cd context_directory

  verify_git_clean warn_only: true
  verify_repo_identity git_remote: git_remote, warn_only: true
  verify_library_version gem_name, version, warn_only: true
  verify_changelog_content gem_name, version, warn_only: true
  verify_github_checks warn_only: true

  puts "WARNING: You are releasing locally, outside the normal process!", :bold, :red
  unless confirm "Build and push #{gem_name} #{version} gem? ", default: false
    error "Release aborted"
  end

  build_gem gem_name, version
  push_gem gem_name, version, dry_run: dry_run
end
