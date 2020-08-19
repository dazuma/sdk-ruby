# frozen_string_literal: true

desc "Trigger a release"

include :exec, exit_on_nonzero_status: true
include :terminal, styled: true
include :fileutils
include "release-tools"

required_arg :gem_name
required_arg :version

flag :git_remote, "--git-remote=VAL", default: "origin"
flag :yes, "--yes", "-y"

def run
  cd context_directory

  puts "Running prechecks...", :bold
  verify_git_clean
  verify_repo_identity git_remote: git_remote
  verify_library_version gem_name, version
  changelog_entry = verify_changelog_content gem_name, version
  verify_github_checks

  puts "Found changelog entry:", :bold
  puts changelog_entry
  if !yes && !confirm("Release #{gem_name} #{version}? ", :bold, default: true)
    error "Release aborted"
  end

  push_github_release sha, gem_name, version, changelog_entry
  puts "SUCCESS: Created release", :green, :bold
end
