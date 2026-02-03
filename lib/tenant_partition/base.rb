# frozen_string_literal: true

module TenantPartition
  # Clase base abstracta para definir modelos de infraestructura de particionamiento.
  # Provee métodos para manipular tablas físicas (DDL) y mover datos.
  class Base
    include ActiveModel::Model
    include ActiveModel::Attributes

    # @!method partition_key
    #   @return [Symbol] La clave de partición configurada para esta clase.

    # Hook de herencia para definir atributos automáticamente.
    def self.inherited(subclass)
      super
      key = TenantPartition.configuration&.partition_key
      subclass.attribute key if key
    end

    class << self
      attr_writer :parent_table, :prefix, :default_table

      # @return [String] Nombre de la tabla padre en la base de datos.
      def parent_table
        @parent_table ||= name.demodulize.underscore.pluralize
      end

      # @return [Symbol] Clave de partición activa (prioridad a configuración local).
      def partition_key
        @partition_key ||= TenantPartition.configuration&.partition_key ||
                           raise(TenantPartition::Error, "Clave de partición no configurada.")
      end

      # Establece una clave de partición específica para esta clase.
      # @param value [Symbol] Nombre de la columna.
      def partition_key=(value)
        @partition_key = value
        attribute value
      end

      # @return [String] Prefijo para los nombres de tablas hijas.
      def prefix
        @prefix ||= "#{parent_table}_#{partition_key.to_s.gsub('_id', '')}"
      end

      # @return [String] Nombre de la tabla DEFAULT.
      def default_table
        @default_table ||= "#{parent_table}_default"
      end

      # @return [ActiveRecord::ConnectionAdapters::PostgreSQLAdapter] Conexión a DB.
      def connection
        ActiveRecord::Base.connection
      end

      # Crea la partición física para un valor dado.
      # @param value [String, Integer] Valor del tenant.
      # @return [TenantPartition::Base] Instancia representando la partición.
      def create(value)
        payload = { partition_key: partition_key, value: value, table: parent_table }

        ActiveSupport::Notifications.instrument("create.tenant_partition", payload) do
          name = partition_name(value)
          sql = "CREATE TABLE IF NOT EXISTS #{name} PARTITION OF #{parent_table} FOR VALUES IN ('#{value}');"
          connection.execute(sql)
          new(partition_key => value)
        end
      end

      # Genera el nombre de tabla sanitizado para un valor.
      # @param value [Object] Valor del tenant.
      # @return [String] Nombre de tabla SQL seguro.
      def partition_name(value)
        sanitized = value.to_s.gsub("-", "_")
        "#{prefix}_#{sanitized}"
      end

      # Verifica existencia física de la tabla en Postgres.
      # @param value [Object] Valor del tenant.
      # @return [Boolean]
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

      # Busca una partición existente.
      # @return [TenantPartition::Base, nil]
      def find(value)
        new(partition_key => value) if exists?(value)
      end
    end

    # --- Métodos de Instancia ---

    # @return [Object] Valor actual del ID de partición de esta instancia.
    def partition_id
      public_send(self.class.partition_key)
    end

    # @return [String] Nombre físico de la tabla asociada.
    def partition_table_name
      self.class.partition_name(partition_id)
    end

    # @return [Boolean] Si la tabla física existe.
    def persisted?
      self.class.exists?(partition_id)
    end

    # Mueve datos desde la tabla default a esta partición en lotes.
    # @param batch_size [Integer] Tamaño del lote transaccional.
    # @return [Integer] Total de registros movidos.
    def populate_from_default(batch_size: 5000)
      return 0 unless persisted?

      key = self.class.partition_key
      val = partition_id
      parent = self.class.parent_table

      payload = { partition_key: key, value: val, parent_table: parent }

      ActiveSupport::Notifications.instrument("populate.tenant_partition", payload) do |notification_payload|
        total_moved = perform_batch_move(batch_size)
        notification_payload[:count] = total_moved
        total_moved
      end
    end

    # Elimina la tabla física (DDL).
    # @return [Boolean] true si se eliminó correctamente.
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

    private

    def perform_batch_move(batch_size)
      total_moved = 0
      loop do
        batch_count = move_single_batch(batch_size)
        total_moved += batch_count
        break if batch_count < batch_size
      end
      total_moved
    end

    def move_single_batch(batch_size)
      default = self.class.default_table
      parent  = self.class.parent_table
      key     = self.class.partition_key
      val     = partition_id

      self.class.connection.transaction do
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
        self.class.connection.execute(move_sql).cmd_tuples
      end
    end
  end
end
