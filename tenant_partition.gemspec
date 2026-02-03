# frozen_string_literal: true

require_relative "lib/tenant_partition/version"

Gem::Specification.new do |spec|
  spec.name = "tenant_partition"
  spec.version = TenantPartition::VERSION
  spec.authors = ["gabriel"]
  spec.email = ["gedera@wispro.co"]

  spec.summary = "Gestión de particiones PostgreSQL al estilo Rails."
  spec.description = "Framework de infraestructura para Rails 7.1+ que automatiza el particionamiento nativo " \
                     "(List Partitioning). Incluye soporte para Composite Primary Keys, orquestación de " \
                     "tenants y migraciones zero-downtime."
  spec.homepage = "https://github.com/gedera/tenant_partition"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["source_code_uri"] = "https://github.com/gedera/tenant_partition"
  spec.metadata["changelog_uri"] = "https://github.com/gedera/tenant_partition/blob/main/CHANGELOG.md"

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

  # Dependencies sorted alphabetically
  spec.add_dependency "activemodel", ">= 7.1"
  spec.add_dependency "activerecord", ">= 7.1"
end
