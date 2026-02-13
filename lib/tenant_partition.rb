# frozen_string_literal: true

require "active_record"
require "active_model"
require "active_support/all"

require_relative "tenant_partition/version"
require_relative "tenant_partition/configuration"
require_relative "tenant_partition/safety_guard"
require_relative "tenant_partition/maintenance"
require_relative "tenant_partition/concerns/partitioned"
require_relative "tenant_partition/concerns/controller"

require_relative "tenant_partition/railtie" if defined?(Rails)

# Fachada principal para la gestión y orquestación de particionamiento en PostgreSQL.
# Permite configurar la gema y ejecutar comandos globales de creación/eliminación de tenants.
module TenantPartition
  class Error < StandardError; end

  extend Maintenance

  class << self
    # @return [TenantPartition::Configuration] la configuración actual.
    attr_accessor :configuration

    # Array para almacenar los modelos que han activado el particionamiento.
    # @return [Array<Class>] Lista de clases ActiveRecord registradas.
    def registered_models
      @registered_models ||= []
    end

    # Registra un modelo como particionado.
    # Método llamado automáticamente por el concern {TenantPartition::Concerns::Partitioned}.
    #
    # @api private
    # @param model [Class] La clase del modelo a registrar.
    # @return [Array<Class>] La lista actualizada de modelos.
    def register_model(model)
      registered_models << model
      registered_models.uniq!
    end

    # Devuelve la lista de modelos particionados activos en la aplicación.
    # @return [Array<Class>] Lista de modelos.
    def partitionable_models
      registered_models
    end

    # Bloque de configuración global para la gema.
    #
    # @example Configurar el ISP ID como clave
    #   TenantPartition.configure do |config|
    #     config.partition_key = :isp_id
    #   end
    #
    # @yield [configuration] Objeto de configuración.
    # @return [void]
    def configure
      self.configuration ||= Configuration.new
      yield(configuration)
      SafetyGuard.validate!
    end

    # Crea la infraestructura de particiones (tablas) para un tenant específico.
    # Itera sobre todos los modelos registrados y crea su tabla particionada correspondiente.
    #
    # @param partition_id [Integer, String] El identificador del tenant (ej. ISP ID).
    # @return [void]
    def create!(partition_id)
      ensure_models_loaded!

      log_info "CREATE", "Iniciando aprovisionamiento para ID: #{partition_id}"

      partitionable_models.each do |model|
        process_creation(model, partition_id)
      end
    end

    # Destruye la infraestructura de particiones para un tenant específico.
    # ¡CUIDADO! Esto elimina físicamente las tablas y sus datos.
    #
    # @param partition_id [Integer, String] El identificador del tenant.
    # @return [void]
    def destroy!(partition_id)
      ensure_models_loaded!

      log_info "DESTROY", "Eliminando infraestructura para ID: #{partition_id}"

      partitionable_models.each do |model|
        process_destruction(model, partition_id)
      end
    end

    # Verifica si existe infraestructura creada para un tenant.
    #
    # @param partition_id [Integer, String] El identificador del tenant.
    # @return [Boolean] true si al menos un modelo tiene la tabla creada.
    def exists?(partition_id)
      partitionable_models.any? { |model| model.partition_table_exists?(partition_id) }
    end

    # @api private
    def log_info(tag, msg)  = logger&.info(format_log(tag, msg))
    # @api private
    def log_warn(tag, msg)  = logger&.warn(format_log(tag, msg))
    # @api private
    def log_error(tag, msg) = logger&.error(format_log(tag, msg))

    private

    def format_log(tag, msg) = "[TenantPartition] [#{tag}] #{msg}"
    def logger = (defined?(Rails) ? Rails.logger : Logger.new($stdout))

    def ensure_models_loaded!
      return unless defined?(Rails) && !Rails.configuration.eager_load
      Rails.application.eager_load!
    end

    def process_creation(model, partition_id)
      if model.partition_table_exists?(partition_id)
        log_info "SKIP", "#{model.name}: La partición ya existe."
      else
        model.create_partition(partition_id)
        log_info "OK", "#{model.name}: Partición creada exitosamente."
      end
    end

    def process_destruction(model, partition_id)
      if model.partition_table_exists?(partition_id)
        model.drop_partition(partition_id)
        log_info "DROP", "#{model.name}: Partición eliminada."
      else
        log_info "SKIP", "#{model.name}: No existe partición para borrar."
      end
    end
  end
end
