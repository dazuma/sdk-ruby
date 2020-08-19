# frozen_string_literal: true

desc "Run release prechecks for the cloud_events gem"

include :fileutils
include :terminal
include "release-tools"

required_arg :gem_name
required_arg :version

flag :git_remote, "--git-remote=VAL", default: "origin"

def run
  cd context_directory

  puts "Running prechecks for releasing #{gem_name} #{version}...", :bold
  verify_git_clean
  verify_repo_identity git_remote: git_remote
  verify_library_version gem_name, version
  verify_changelog_content gem_name, version
  verify_github_checks

  puts "SUCCESS", :green, :bold
end
