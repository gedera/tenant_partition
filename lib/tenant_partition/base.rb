# frozen_string_literal: true

require_relative "concerns/data_mover"

module TenantPartition
  # Clase base abstracta para definir modelos de infraestructura de particionamiento.
  # Hereda de esta clase para habilitar operaciones DDL (Create/Drop) sobre tus tablas particionadas.
  #
  # @abstract
  class Base
    include ActiveModel::Model
    include ActiveModel::Attributes
    include TenantPartition::Concerns::DataMover

    # Hook de herencia para definir automáticamente el atributo de partición en las subclases.
    # @param subclass [Class] La clase que hereda.
    def self.inherited(subclass)
      super
      key = TenantPartition.configuration&.partition_key
      subclass.attribute key if key
    end

    class << self
      attr_writer :parent_table, :prefix, :default_table

      # @return [String] Nombre de la tabla padre (ej: 'conversations').
      def parent_table
        @parent_table ||= name.demodulize.underscore.pluralize
      end

      # @return [Symbol] Clave de partición configurada (ej: :isp_id).
      # @raise [TenantPartition::Error] Si no hay configuración global ni local.
      def partition_key
        @partition_key ||= TenantPartition.configuration&.partition_key ||
                           raise(TenantPartition::Error, "Clave de partición no configurada.")
      end

      # Define manualmente la clave de partición para esta clase, sobrescribiendo la global.
      # @param value [Symbol] Nombre de la columna.
      def partition_key=(value)
        @partition_key = value
        attribute value
      end

      # @return [String] Prefijo para las tablas particionadas (ej: 'conversations_isp').
      def prefix
        @prefix ||= "#{parent_table}_#{partition_key.to_s.gsub("_id", "")}"
      end

      # @return [String] Nombre de la tabla DEFAULT.
      def default_table
        @default_table ||= "#{parent_table}_default"
      end

      # @return [ActiveRecord::ConnectionAdapters::PostgreSQLAdapter] Conexión activa a la DB.
      def connection
        ActiveRecord::Base.connection
      end

      # Crea una nueva partición física en la base de datos.
      # @param value [String, Integer] El valor discriminador del tenant (ej: UUID).
      # @return [TenantPartition::Base] Una instancia representando la nueva partición.
      def create(value)
        payload = { partition_key: partition_key, value: value, table: parent_table }

        ActiveSupport::Notifications.instrument("create.tenant_partition", payload) do
          name = partition_name(value)
          sql = "CREATE TABLE IF NOT EXISTS #{name} PARTITION OF #{parent_table} FOR VALUES IN ('#{value}');"
          connection.execute(sql)
          new(partition_key => value)
        end
      end

      # Genera el nombre físico de la tabla particionada, sanitizando el valor.
      # @param value [Object] Valor del tenant.
      # @return [String] Nombre de la tabla (ej: 'conversations_isp_123').
      def partition_name(value)
        sanitized = value.to_s.gsub("-", "_")
        "#{prefix}_#{sanitized}"
      end

      # Verifica si la tabla particionada existe físicamente en el catálogo de PostgreSQL.
      # @param value [Object] Valor del tenant.
      # @return [Boolean] true si la tabla existe.
      def exists?(value)
        name = partition_name(value)
        sql = <<~SQL.squish
          SELECT 1 FROM pg_class c
          JOIN pg_inherits i ON c.oid = i.inhrelid
          JOIN pg_class p ON i.inhparent = p.oid
          WHERE p.relname = '#{parent_table}' AND c.relname = '#{name}';
        SQL
        connection.execute(sql).any?
      end

      # Busca una partición existente.
      # @param value [Object] Valor del tenant.
      # @return [TenantPartition::Base, nil] Instancia si existe, nil si no.
      def find(value)
        new(partition_key => value) if exists?(value)
      end
    end

    # --- Métodos de Instancia ---

    # @return [Object] Valor del ID de partición de esta instancia.
    def partition_id
      public_send(self.class.partition_key)
    end

    # @return [String] Nombre de la tabla física correspondiente a esta instancia.
    def partition_table_name
      self.class.partition_name(partition_id)
    end

    # @return [Boolean] Si la partición está persistida en base de datos.
    def persisted?
      self.class.exists?(partition_id)
    end

    # Elimina la partición física de la base de datos (DETACH + DROP).
    # @return [Boolean] true si la eliminación fue exitosa.
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
