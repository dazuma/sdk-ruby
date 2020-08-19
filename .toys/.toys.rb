# frozen_string_literal: true

expand :clean, paths: :gitignore

expand :minitest, libs: ["lib"], bundler: true

expand :rubocop do |t|
  t.options = ["lib", "test", "examples", ".toys", ".toys/release/.lib"]
  t.use_bundler
end

expand :yardoc do |t|
  t.generate_output_flag = true
  t.fail_on_warning = true
  t.fail_on_undocumented_objects = true
  t.use_bundler
end

expand :gem_build

expand :gem_build, name: "install", install_gem: true
