# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"

module TenantPartition
  module Generators
    # Generador que construye automáticamente las migraciones necesarias para realizar
    # una migración "Zero-Downtime" de una tabla legacy a una particionada.
    #
    # @example Uso básico
    #   rails g tenant_partition:online_migration versions isp_id
    class OnlineMigrationGenerator < Rails::Generators::Base
      include Rails::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      argument :table_name, type: :string, banner: "nombre_de_la_tabla_actual"
      argument :partition_key, type: :string, banner: "columna_partition_key"

      desc "Genera las migraciones en dos fases (Preparación y Cutover) para migrar una tabla en vivo."

      # Requerido por Rails::Generators::Migration para saber cómo numerar los archivos.
      def self.next_migration_number(dirname)
        ActiveRecord::Generators::Base.next_migration_number(dirname)
      end

      # Crea la primera migración (Fase de Preparación y Triggers).
      def create_preparation_migration
        migration_template(
          "prepare_online_migration.rb.erb",
          "db/migrate/prepare_online_migration_for_#{table_name}.rb",
          migration_version: migration_version
        )
      end

      # Crea la segunda migración (Fase de Cutover).
      # Le añadimos un pequeño delay de 1 segundo para asegurarnos de que el timestamp
      # del archivo sea mayor que el de la primera migración.
      def create_cutover_migration
        sleep 1
        migration_template(
          "complete_online_migration.rb.erb",
          "db/migrate/complete_online_migration_for_#{table_name}.rb",
          migration_version: migration_version
        )
      end

      # Muestra las instrucciones finales en la consola.
      def show_readme
        readme "ONLINE_MIGRATION_README" if behavior == :invoke
      end

      private

      def migration_version
        "[#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}]"
      end

      def target_table
        "#{table_name}_partitioned"
      end
    end
  end
end
