# frozen_string_literal: true

require_relative "lib/active_partition/version"

Gem::Specification.new do |spec|
  spec.name = "active_partition"
  spec.version = ActivePartition::VERSION
  spec.authors = ["gabriel"]
  spec.email = ["gedera@wispro.co"]

  spec.summary = "Gestión de particiones PostgreSQL al estilo Rails."
  spec.description = "Framework de infraestructura para Rails 7.1+ que automatiza el particionamiento nativo (List Partitioning). Incluye soporte para Composite Primary Keys, orquestación de tenants y migraciones zero-downtime."
  spec.homepage = "https://github.com/gedera/active_partition"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  # spec.metadata["allowed_push_host"] = "TODO: Set to your gem server 'https://example.com'"
  # spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/gedera/active_partition"
  spec.metadata["changelog_uri"] = "https://github.com/gedera/active_partition/blob/main/CHANGELOG.md"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ Gemfile .gitignore .github/ .rubocop.yml])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  # Uncomment to register a new dependency of your gem
  # spec.add_dependency "example-gem", "~> 1.0"
  spec.add_dependency "activerecord", ">= 7.1"
  spec.add_dependency "activemodel", ">= 7.1"

  # For more information and examples about making a new gem, check out our
  # guide at: https://bundler.io/guides/creating_gem.html
end
