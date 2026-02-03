# frozen_string_literal: true

module TenantPartition
  module Concerns
    # Concern para modelos Rails (ApplicationRecord).
    # Configura Primary Keys Compuestas y Scopes de partición.
    module Partitioned
      extend ActiveSupport::Concern

      included do
        TenantPartition::Concerns::Partitioned.configure_model(self)
      end

      class_methods do
        def inherited(subclass)
          super
          TenantPartition::Concerns::Partitioned.configure_model(subclass)
        end

        # Permite definir manualmente la clave de partición para este modelo.
        # @param key [Symbol] Nombre de la columna.
        def partitioned_by(key)
          TenantPartition::Concerns::Partitioned.apply_configuration(self, key)
        end
      end

      # Configura el modelo detectando la clave de partición.
      # @api private
      def self.configure_model(klass)
        return if klass.respond_to?(:abstract_class?) && klass.abstract_class?

        key_to_use = resolve_partition_key(klass)
        apply_configuration(klass, key_to_use) if key_to_use.present?
      end

      # Resuelve la clave de partición por introspección o configuración global.
      # @api private
      def self.resolve_partition_key(klass)
        infra_class_name = "Partition::#{klass.name}"
        infra_class = infra_class_name.safe_constantize

        # Prioridad a la configuración del modelo de infraestructura si existe.
        return infra_class.partition_key if infra_class&.respond_to?(:partition_key)

        TenantPartition.configuration&.partition_key
      end

      # Aplica la configuración de CPK y scopes.
      # @api private
      def self.apply_configuration(klass, key)
        return if klass.primary_key.is_a?(Array) && klass.primary_key.include?(key.to_s)

        klass.primary_key = [:id, key]
        klass.scope :for_partition, ->(value) { where(key => value) }
      end
    end
  end
end
