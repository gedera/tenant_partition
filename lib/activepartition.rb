# frozen_string_literal: true

require "active_record"
require "active_model"
require "active_support/all"

# Carga de la versión y componentes internos
require_relative "activepartition/version"
require_relative "activepartition/configuration"
require_relative "activepartition/safety_guard"
require_relative "activepartition/base"
require_relative "activepartition/concerns/partitioned"
require_relative "activepartition/concerns/controller"

# Integración con Ruby on Rails
require_relative "activepartition/railtie" if defined?(Rails)

# ActivePartition es el punto de entrada principal para la gestión de particionamiento
# en PostgreSQL dentro de aplicaciones Rails.
#
# Actúa como una **Fachada** que centraliza:
# 1. Configuración de la gema.
# 2. Orquestación del ciclo de vida de los tenants (Crear/Borrar particiones).
# 3. Mantenimiento y limpieza de datos huérfanos.
module ActivePartition
  # Error base para todas las excepciones de la gema.
  class Error < StandardError; end

  class << self
    # @return [ActivePartition::Configuration] El objeto de configuración global.
    attr_accessor :configuration

    # Configura la gema mediante un bloque e inicializa las validaciones de seguridad.
    #
    # @yieldparam [ActivePartition::Configuration] config
    # @return [void]
    def configure
      self.configuration ||= Configuration.new
      yield(configuration)
      SafetyGuard.validate!
    end

    # =========================================================================
    # GRUPO 1: ORQUESTACIÓN DE TENANTS (Ciclo de Vida)
    # =========================================================================

    # Crea las particiones físicas para un tenant específico en TODOS los modelos registrados.
    #
    # Este método es **idempotente**: verifica si la partición existe antes de intentar crearla,
    # evitando errores de SQL.
    #
    # @param partition_id [String, Integer] El ID del tenant (ej: el UUID del ISP).
    # @return [void]
    def create!(partition_id)
      ensure_models_loaded!

      log_info "CREATE", "Iniciando aprovisionamiento para ID: #{partition_id}"

      partitionable_models.each do |model|
        if model.exists?(partition_id)
          log_info "SKIP", "#{model.name}: La partición ya existe."
        else
          model.create(partition_id)
          log_info "OK", "#{model.name}: Partición creada exitosamente."
        end
      end
    end

    # Elimina (DETACH + DROP) las particiones físicas de un tenant en TODOS los modelos.
    #
    # @warning Esta acción es destructiva e irreversible. Borra los datos físicos.
    #
    # @param partition_id [String, Integer] El ID del tenant a eliminar.
    # @return [void]
    def destroy!(partition_id)
      ensure_models_loaded!

      log_info "DESTROY", "Eliminando infraestructura para ID: #{partition_id}"

      partitionable_models.each do |model|
        if model.exists?(partition_id)
          partition = model.find(partition_id)
          if partition.destroy
            log_info "DROP", "#{model.name}: Partición eliminada."
          else
            log_error "FAIL", "#{model.name}: No se pudo eliminar la partición."
          end
        else
          log_info "SKIP", "#{model.name}: No existe partición para borrar."
        end
      end
    end

    # =========================================================================
    # GRUPO 2: MANTENIMIENTO Y OPS (Audit & Cleanup)
    # =========================================================================

    # Audita todas las tablas DEFAULT buscando registros "huérfanos".
    #
    # Un registro huérfano es aquel que se insertó en la tabla padre pero, al no existir
    # su partición correspondiente en ese momento, cayó en la tabla _default.
    #
    # @return [Hash{String => Integer}] Mapa con el nombre del modelo y la cantidad de registros huérfanos.
    # @example
    #   ActivePartition.audit
    #   # => { "Partition::Message" => 150, "Partition::Log" => 0 }
    def audit
      ensure_models_loaded!
      report = {}

      log_info "AUDIT", "Iniciando auditoría de tablas DEFAULT..."

      partitionable_models.each do |model|
        count = count_default_rows(model)
        report[model.name] = count

        if count > 0
          log_warn "ALERTA", "#{model.name}: #{count} registros huérfanos encontrados."
        else
          log_info "OK", "#{model.name}: Tabla default limpia."
        end
      end

      report
    end

    # Realiza una limpieza global moviendo registros huérfanos a sus particiones correctas.
    #
    # 1. Identifica qué IDs de tenant tienen datos en las tablas DEFAULT.
    # 2. Verifica si ya existe la partición física para esos IDs.
    # 3. Mueve los datos atómicamente.
    #
    # @return [void]
    def cleanup!
      ensure_models_loaded!
      key = configuration.partition_key

      log_info "CLEANUP", "Iniciando proceso de limpieza global..."

      partitionable_models.each do |model|
        # Obtenemos los IDs únicos presentes en la tabla default
        orphan_ids = fetch_orphan_ids(model, key)

        if orphan_ids.empty?
          log_info "OK", "#{model.name}: Sin datos huérfanos."
          next
        end

        log_warn "FIX", "#{model.name}: Procesando #{orphan_ids.count} tenants con datos huérfanos."

        orphan_ids.each do |id|
          partition = model.find(id)

          if partition
            moved = partition.populate_from_default
            log_info "MOVE", "  -> ID #{id}: #{moved} registros recuperados."
          else
            log_error "ERROR", "  -> ID #{id}: La partición física no existe. Cree el tenant primero."
          end
        end
      end
    end

    private

    # Encuentra todas las clases cargadas que heredan de ActivePartition::Base.
    # @return [Array<Class>]
    def partitionable_models
      ObjectSpace.each_object(Class).select { |klass| klass < ActivePartition::Base }
    end

    # Cuenta registros en la tabla default de un modelo de infraestructura.
    # @return [Integer]
    def count_default_rows(model)
      model.connection.select_value("SELECT count(*) FROM #{model.default_table}").to_i
    rescue ActiveRecord::StatementInvalid
      0
    end

    # Obtiene los IDs de partición distintos que existen en la tabla default.
    # @return [Array<String>]
    def fetch_orphan_ids(model, key)
      sql = "SELECT DISTINCT #{key} FROM #{model.default_table} WHERE #{key} IS NOT NULL"
      model.connection.execute(sql).map { |r| r[key.to_s] }
    rescue ActiveRecord::StatementInvalid
      []
    end

    # Asegura que Rails haya cargado los modelos de infraestructura.
    # Vital en modo Development donde la carga es perezosa (Lazy Loading).
    def ensure_models_loaded!
      return unless defined?(Rails)

      partition_dir = Rails.root.join("app/models/partition")
      return unless Dir.exist?(partition_dir)

      # Forzamos la carga de todos los archivos en app/models/partition/
      Dir[partition_dir.join("**/*.rb")].each { |file| require_dependency file }
    end

    # Helpers de Logging
    def log_info(tag, msg)  = logger&.info(format_log(tag, msg))
    def log_warn(tag, msg)  = logger&.warn(format_log(tag, msg))
    def log_error(tag, msg) = logger&.error(format_log(tag, msg))

    def format_log(tag, msg)
      "[ActivePartition] [#{tag}] #{msg}"
    end

    def logger
      defined?(Rails) ? Rails.logger : Logger.new($stdout)
    end
  end
end
