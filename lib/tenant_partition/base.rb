# frozen_string_literal: true

module TenantPartition
  # Clase base para la gestión de infraestructura de particionamiento en PostgreSQL.
  #
  # Proporciona una interfaz para manejar el ciclo de vida de las tablas físicas (Particiones).
  #
  # @abstract Hereda de esta clase para definir un recurso de partición.
  # @example
  #   class Partition::Chat < TenantPartition::Base
  #     # Opcional: Sobrescribir la clave global
  #     self.partition_key = :region_code
  #   end
  class Base
    include ActiveModel::Model
    include ActiveModel::Attributes

    # Registra el atributo de partición en la subclase en el momento de la herencia.
    def self.inherited(subclass)
      super
      # Intentamos definir el atributo por defecto si existe configuración global
      key = TenantPartition.configuration&.partition_key
      subclass.attribute key if key
    end

    class << self
      attr_writer :parent_table, :prefix, :default_table

      # Permite inyectar una clave de partición personalizada por clase
      attr_writer :partition_key

      def parent_table
        @parent_table ||= name.demodulize.underscore.pluralize
      end

      # Prioridad: 1. Clave de la clase, 2. Clave global
      def partition_key
        @partition_key ||= TenantPartition.configuration&.partition_key ||
          raise(TenantPartition::Error, "Clave de partición no configurada.")
      end

      def partition_key=(value)
        @partition_key = value
        attribute value # Define el atributo en ActiveModel automáticamente
      end

      def prefix
        @prefix ||= "#{parent_table}_#{partition_key.to_s.gsub('_id', '')}"
      end

      def default_table
        @default_table ||= "#{parent_table}_default"
      end

      def connection
        ActiveRecord::Base.connection
      end

      # Crea físicamente una partición en PostgreSQL.
      def create(value)
        # Importante: Usamos el método partition_key (no la variable) para respetar overrides
        payload = { partition_key: partition_key, value: value, table: parent_table }

        ActiveSupport::Notifications.instrument("create.tenant_partition", payload) do
          name = partition_name(value)
          sql = "CREATE TABLE IF NOT EXISTS #{name} PARTITION OF #{parent_table} FOR VALUES IN ('#{value}');"
          connection.execute(sql)
          new(partition_key => value)
        end
      end

      def partition_name(value)
        sanitized = value.to_s.gsub('-', '_')
        "#{prefix}_#{sanitized}"
      end

      def exists?(value)
        name = partition_name(value)
        sql = <<-SQL.squish
          SELECT 1 FROM pg_class c
          JOIN pg_inherits i ON c.oid = i.inhrelid
          JOIN pg_class p ON i.inhparent = p.oid
          WHERE p.relname = '#{parent_table}' AND c.relname = '#{name}';
        SQL
        connection.execute(sql).any?
      end

      def find(value)
        new(partition_key => value) if exists?(value)
      end
    end

    # --- Métodos de Instancia ---

    def partition_id
      # CORRECCIÓN: Usamos public_send porque ActiveModel no tiene read_attribute
      # Esto invoca al getter generado dinámicamente (ej: .isp_id)
      public_send(self.class.partition_key)
    end

    def partition_table_name
      self.class.partition_name(partition_id)
    end

    def persisted?
      self.class.exists?(partition_id)
    end

    # Mueve registros desde la tabla por defecto hacia la partición atómicamente.
    def populate_from_default(batch_size: 5000)
      return 0 unless persisted?

      parent  = self.class.parent_table
      default = self.class.default_table
      key     = self.class.partition_key
      val     = partition_id

      payload = { partition_key: key, value: val, parent_table: parent }

      ActiveSupport::Notifications.instrument("populate.tenant_partition", payload) do |notification_payload|
        total_moved = 0

        loop do
          batch_count = 0
          self.class.connection.transaction do
            # Usamos el ID para paginar el borrado/insertado
            move_sql = <<-SQL.squish
              WITH moved_rows AS (
                DELETE FROM #{default}
                WHERE #{key} = '#{val}'
                AND id IN (
                  SELECT id FROM #{default} WHERE #{key} = '#{val}' LIMIT #{batch_size}
                )
                RETURNING *
              )
              INSERT INTO #{parent} SELECT * FROM moved_rows;
            SQL

            result = self.class.connection.execute(move_sql)
            batch_count = result.cmd_tuples
          end

          total_moved += batch_count
          break if batch_count < batch_size
        end

        notification_payload[:count] = total_moved
        total_moved
      end
    end

    def destroy
      return false unless persisted?

      p_name = partition_table_name
      p_table = self.class.parent_table

      self.class.connection.transaction do
        self.class.connection.execute("ALTER TABLE #{p_table} DETACH PARTITION #{p_name};")
        self.class.connection.execute("DROP TABLE IF EXISTS #{p_name};")
      end
      true
    rescue ActiveRecord::StatementInvalid
      false
    end
  end
end
