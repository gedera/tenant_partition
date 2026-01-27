# frozen_string_literal: true

module TenantPartition
  module Concerns
    # Módulo de infraestructura para modelos de negocio (ApplicationRecord).
    #
    # Este concern es el encargado de adaptar el modelo de Rails para trabajar con
    # la estructura de tablas particionadas de PostgreSQL. Su función crítica es
    # configurar las **Primary Keys Compuestas (CPK)** requeridas por Rails 7.1+.
    #
    # ### Estrategia de Resolución de Claves
    # El módulo determina qué columna usar como clave de partición siguiendo este orden de prioridad:
    #
    # 1. **Explícita:** Definida manualmente con `partitioned_by :key` en el modelo.
    # 2. **Inferencia (Convención):** Busca si existe una clase de infraestructura asociada
    #    (ej: para `Conversation` busca `Partition::Conversation`) y utiliza su configuración.
    # 3. **Global:** Utiliza la clave definida en `TenantPartition.configure`.
    #
    # @example Modo Automático (Inferencia)
    #   # Si Partition::LegacyChat tiene `self.partition_key = :region_id`
    #   class LegacyChat < ApplicationRecord
    #     include TenantPartition::Concerns::Partitioned
    #     # Automáticamente configura PK: [:id, :region_id]
    #   end
    #
    # @example Modo Manual (Override)
    #   class Log < ApplicationRecord
    #     include TenantPartition::Concerns::Partitioned
    #     partitioned_by :custom_id
    #   end
    module Partitioned
      extend ActiveSupport::Concern

      included do
        # Punto de entrada para inclusión directa.
        # 'self' es la clase que incluye el módulo.
        TenantPartition::Concerns::Partitioned.configure_model(self)
      end

      class_methods do
        # Hook de Ruby disparado al heredar.
        # Permite incluir el módulo en ApplicationRecord y que la configuración
        # se aplique automáticamente a cada subclase en el momento de su definición.
        #
        # @param subclass [Class] La clase que está heredando.
        def inherited(subclass)
          super
          TenantPartition::Concerns::Partitioned.configure_model(subclass)
        end

        # Define manualmente la clave de partición, ignorando la inferencia y la config global.
        #
        # @param key [Symbol] Nombre de la columna de partición.
        def partitioned_by(key)
          TenantPartition::Concerns::Partitioned.apply_configuration(self, key)
        end
      end

      # --- Métodos de Utilería (Privados de la Gema) ---

      # Orquesta la configuración del modelo.
      # @api private
      def self.configure_model(klass)
        # Ignoramos clases abstractas para evitar errores de tabla inexistente.
        return if klass.respond_to?(:abstract_class?) && klass.abstract_class?

        # Resolvemos la clave correcta según la prioridad establecida.
        key_to_use = resolve_partition_key(klass)

        apply_configuration(klass, key_to_use) if key_to_use.present?
      end

      # Determina la clave de partición inspeccionando la infraestructura y la configuración.
      #
      # @param klass [Class] El modelo de negocio a inspeccionar.
      # @return [Symbol, nil] La clave de partición encontrada o nil.
      # @api private
      def self.resolve_partition_key(klass)
        # 1. Inferencia por Convención:
        #    Buscamos la clase "Partition::NombreDelModelo".
        #    Ej: Conversation -> Partition::Conversation
        infra_class_name = "Partition::#{klass.name}"

        # safe_constantize (ActiveSupport) devuelve la clase si existe, nil si no.
        # No lanza excepciones si la constante no está definida.
        infra_class = infra_class_name.safe_constantize

        if infra_class && infra_class.respond_to?(:partition_key)
          # Si existe el modelo de infraestructura, confiamos en su configuración.
          return infra_class.partition_key
        end

        # 2. Configuración Global (Fallback):
        TenantPartition.configuration&.partition_key
      end

      # Aplica la configuración de Primary Key y Scopes al modelo.
      #
      # @param klass [Class] El modelo a configurar.
      # @param key [Symbol] La clave de partición.
      # @api private
      def self.apply_configuration(klass, key)
        # Idempotencia:
        # Si la clase ya tiene la PK compuesta correcta, no hacemos nada.
        # Esto previene conflictos si se llama múltiples veces.
        return if klass.primary_key.is_a?(Array) && klass.primary_key.include?(key.to_s)

        # A. Configuración de CPK (Composite Primary Keys) - Rails 7.1+
        #    Le dice a Rails que la identidad única es (id + partition_key).
        klass.primary_key = [:id, key]

        # B. Scope de Conveniencia
        #    Permite usar Model.for_partition("uuid")
        klass.scope :for_partition, ->(value) { where(key => value) }
      end
    end
  end
end
