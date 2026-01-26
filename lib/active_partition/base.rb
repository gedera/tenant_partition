# frozen_string_literal: true

module ActivePartition
  # Clase base para la gestión de infraestructura de particionamiento en PostgreSQL.
  #
  # Proporciona una interfaz similar a ActiveRecord para manejar la creación,
  # existencia y migración de datos de particiones físicas.
  #
  # @abstract Hereda de esta clase para definir un recurso de partición.
  # @example
  #   class Partition::Chat < ActivePartition::Base
  #     # Opcional: Sobrescribir la clave global
  #     self.partition_key = :region_code
  #   end
  class Base
    include ActiveModel::Model
    include ActiveModel::Attributes

    # Registra el atributo de partición en la subclase en el momento de la herencia.
    # Esto asegura que la configuración global ya esté cargada cuando se defina el modelo.
    #
    # @param subclass [Class] La clase que hereda de ActivePartition::Base.
    # @return [void]
    def self.inherited(subclass)
      super
      # Intentamos definir el atributo por defecto si existe configuración global
      key = ActivePartition.configuration&.partition_key
      subclass.attribute key if key
    end

    class << self
      attr_writer :parent_table, :prefix, :default_table

      # Permite inyectar una clave de partición personalizada por clase
      attr_writer :partition_key

      # @return [String] Nombre de la tabla padre en PostgreSQL.
      def parent_table
        @parent_table ||= name.demodulize.underscore.pluralize
      end

      # @return [Symbol] El nombre de la columna configurada como discriminador.
      # Prioridad:
      # 1. Clave definida explícitamente en la clase (self.partition_key = :xyz)
      # 2. Clave global de configuración
      # @raise [ActivePartition::Error] Si no hay ninguna clave configurada.
      def partition_key
        @partition_key ||= ActivePartition.configuration&.partition_key ||
          raise(ActivePartition::Error, "Clave de partición no configurada.")
      end

      # Setter personalizado para definir el atributo en ActiveModel al momento de asignar.
      # @param value [Symbol] El nombre de la nueva columna de partición.
      def partition_key=(value)
        @partition_key = value
        # Define el atributo en el modelo automáticamente para que ActiveModel lo reconozca
        attribute value
      end

      # Infiere el prefijo para las particiones basado en el nombre de la tabla y la clave.
      # @return [String] Ej: "messages_isp" o "logs_region"
      def prefix
        @prefix ||= "#{parent_table}_#{partition_key.to_s.gsub('_id', '')}"
      end

      # Infiere el nombre de la tabla por defecto para registros huérfanos.
      # @return [String]
      def default_table
        @default_table ||= "#{parent_table}_default"
      end

      # @return [ActiveRecord::ConnectionAdapters::AbstractAdapter]
      def connection
        ActiveRecord::Base.connection
      end

      # --- Operaciones de Infraestructura ---

      # Crea físicamente una partición en PostgreSQL.
      #
      # @param value [Object] El valor del ID para el cual crear la partición.
      # @return [ActivePartition::Base] Una nueva instancia del recurso.
      def create(value)
        # Usamos el método partition_key para asegurar que leemos el correcto (local o global)
        payload = { partition_key: partition_key, value: value, table: parent_table }

        ActiveSupport::Notifications.instrument("create.active_partition", payload) do
          name = partition_name(value)
          sql = "CREATE TABLE IF NOT EXISTS #{name} PARTITION OF #{parent_table} FOR VALUES IN ('#{value}');"
          connection.execute(sql)
          new(partition_key => value)
        end
      end

      # Genera el nombre de la tabla física sanitizando guiones (común en UUIDs).
      # @param value [Object]
      # @return [String]
      def partition_name(value)
        sanitized = value.to_s.gsub('-', '_')
        "#{prefix}_#{sanitized}"
      end

      # Verifica mediante el catálogo de sistema de Postgres si la tabla existe.
      # @param value [Object]
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

      # Busca una partición por su valor de ID.
      # @param value [Object]
      # @return [ActivePartition::Base, nil]
      def find(value)
        new(partition_key => value) if exists?(value)
      end
    end

    # --- Métodos de Instancia ---

    # @return [Object] El valor del ID de esta partición.
    def partition_id
      read_attribute(self.class.partition_key)
    end

    # @return [String] Nombre físico de la tabla en la DB.
    def partition_table_name
      self.class.partition_name(partition_id)
    end

    # @return [Boolean] true si la tabla existe físicamente.
    def persisted?
      self.class.exists?(partition_id)
    end

    # Mueve registros desde la tabla por defecto hacia la partición atómicamente.
    #
    # @param batch_size [Integer] Registros por lote para evitar bloqueos largos.
    # @return [Integer] Total de registros migrados.
    def populate_from_default(batch_size: 5000)
      return 0 unless persisted?

      parent  = self.class.parent_table
      default = self.class.default_table
      key     = self.class.partition_key
      val     = partition_id

      payload = { partition_key: key, value: val, parent_table: parent }

      ActiveSupport::Notifications.instrument("populate.active_partition", payload) do |notification_payload|
        total_moved = 0

        loop do
          batch_count = 0
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

    # Desvincula y elimina la partición físicamente.
    # @return [Boolean]
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
