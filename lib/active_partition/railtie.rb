# frozen_string_literal: true

require "rails/railtie"

module ActivePartition
  # Railtie encargado de integrar ActivePartition en el ciclo de vida de Rails.
  #
  # Carga las tareas Rake de la gema en la aplicación host
  rake_tasks do
    load "active_partition/tasks/maintenance.rake"
  end

  # Inyecta los helpers de migración en el adaptador de PostgreSQL de ActiveRecord
  # cuando la aplicación carga sus componentes de base de datos.
  class Railtie < Rails::Railtie
    initializer "active_partition.insert_schema_statements" do
      ActiveSupport.on_load(:active_record) do
        require "active_partition/schema/statements"

        # Solo incluimos los helpers si el adaptador es PostgreSQL
        if connection_db_config.adapter == "postgresql"
          ActiveRecord::ConnectionAdapters::PostgreSQLAdapter.include ActivePartition::Schema::Statements
        end
      end
    end
  end
end
