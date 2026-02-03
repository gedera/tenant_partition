# frozen_string_literal: true

require "active_record"
require "active_model"
require "active_support/all"

require_relative "tenant_partition/version"
require_relative "tenant_partition/configuration"
require_relative "tenant_partition/safety_guard"
require_relative "tenant_partition/base"
require_relative "tenant_partition/maintenance"
require_relative "tenant_partition/concerns/partitioned"
require_relative "tenant_partition/concerns/controller"

require_relative "tenant_partition/railtie" if defined?(Rails)

# Fachada principal para la gestión y orquestación de particionamiento en PostgreSQL.
# Centraliza la configuración, creación de particiones y mantenimiento.
module TenantPartition
  class Error < StandardError; end

  # Incorpora las funcionalidades de Auditoría y Limpieza.
  extend Maintenance

  class << self
    # @return [TenantPartition::Configuration] Objeto de configuración global.
    attr_accessor :configuration

    # Bloque de configuración e inicialización.
    # @yieldparam [TenantPartition::Configuration] config
    def configure
      self.configuration ||= Configuration.new
      yield(configuration)
      SafetyGuard.validate!
    end

    # Crea las particiones físicas para un tenant en todos los modelos registrados.
    # @param partition_id [String, Integer] Identificador del tenant.
    def create!(partition_id)
      ensure_models_loaded!
      log_info "CREATE", "Iniciando aprovisionamiento para ID: #{partition_id}"

      partitionable_models.each do |model|
        process_creation(model, partition_id)
      end
    end

    # Elimina irreversiblemente las particiones y datos de un tenant.
    # @param partition_id [String, Integer] Identificador del tenant.
    def destroy!(partition_id)
      ensure_models_loaded!
      log_info "DESTROY", "Eliminando infraestructura para ID: #{partition_id}"

      partitionable_models.each do |model|
        process_destruction(model, partition_id)
      end
    end

    # Verifica si existe infraestructura creada para un tenant.
    # @param partition_id [String, Integer] Identificador del tenant.
    # @return [Boolean] true si existe al menos una tabla particionada.
    def exists?(partition_id)
      ensure_models_loaded!
      partitionable_models.any? { |model| model.exists?(partition_id) }
    end

    # --- Shared Helpers (Accesibles por Maintenance) ---

    # Fuerza la carga de los modelos de partición en entornos con Lazy Loading (Dev).
    def ensure_models_loaded!
      return unless defined?(Rails)

      partition_dir = Rails.root.join("app/models/partition")
      return unless Dir.exist?(partition_dir)

      Dir[partition_dir.join("**/*.rb")].each { |file| require_dependency file }
    end

    # Retorna todas las subclases de TenantPartition::Base cargadas en memoria.
    # @return [Array<Class>] Lista de clases de modelos.
    def partitionable_models
      ObjectSpace.each_object(Class).select { |klass| klass < TenantPartition::Base }
    end

    # --- Logging ---

    def log_info(tag, msg)  = logger&.info(format_log(tag, msg))
    def log_warn(tag, msg)  = logger&.warn(format_log(tag, msg))
    def log_error(tag, msg) = logger&.error(format_log(tag, msg))
    def format_log(tag, msg) = "[TenantPartition] [#{tag}] #{msg}"
    def logger = (defined?(Rails) ? Rails.logger : Logger.new($stdout))

    private

    def process_creation(model, partition_id)
      if model.exists?(partition_id)
        log_info "SKIP", "#{model.name}: La partición ya existe."
      else
        model.create(partition_id)
        log_info "OK", "#{model.name}: Partición creada exitosamente."
      end
    end

    def process_destruction(model, partition_id)
      if model.exists?(partition_id)
        if model.find(partition_id).destroy
          log_info "DROP", "#{model.name}: Partición eliminada."
        else
          log_error "FAIL", "#{model.name}: No se pudo eliminar la partición."
        end
      else
        log_info "SKIP", "#{model.name}: No existe partición para borrar."
      end
    end
  end
end
