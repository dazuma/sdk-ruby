# frozen_string_literal: true

desc "Run release prechecks for the cloud_events gem"

include :fileutils
include :terminal
include "release-tools"

required_arg :gem_name
required_arg :version

def run
  cd context_directory

  puts "Running prechecks for releasing #{gem_name} #{version}...", :bold
  verify_git_clean
  verify_library_version gem_name, version
  verify_changelog_content gem_name, version
  verify_github_checks

  puts "SUCCESS", :green, :bold
end
