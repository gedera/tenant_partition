# frozen_string_literal: true

require "rails/generators"

module TenantPartition
  module Generators
    # Generador encargado de crear el controlador API para la orquestación de tenants.
    #
    # Este generador facilita la creación de un punto de entrada (Endpoint) para que sistemas externos
    # o administradores puedan gestionar el ciclo de vida de las particiones (Crear/Borrar/Consultar).
    #
    # Soporta la especificación de un **Namespace** opcional para organizar el controlador
    # dentro de una carpeta específica (ej: `Ops`, `System`, `Admin`).
    #
    # @example Uso básico (Namespace por defecto: tenant_partition)
    #   rails g tenant_partition:api_controller
    #
    # @example Uso con Namespace personalizado (ej: Ops)
    #   rails g tenant_partition:api_controller Ops
    #
    class ApiControllerGenerator < Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)

      # Define el argumento posicional para el namespace.
      # Si el usuario no lo provee, se utiliza "system" por defecto.
      #
      # @!attribute [r] namespace_name
      #   @return [String] El nombre del módulo/carpeta donde se alojará el controlador.
      argument :namespace_name, type: :string, default: "system", banner: "namespace"

      desc "Crea un controlador API profesional para gestionar el ciclo de vida de los Tenants, " \
           "incluyendo rutas y boilerplate de seguridad."

      # Genera el archivo del controlador utilizando la plantilla ERB.
      #
      # Calcula dinámicamente el nombre de la carpeta y del módulo basándose en el
      # argumento `namespace_name` para asegurar que la estructura de archivos
      # coincida con la nomenclatura de Ruby (CamelCase vs snake_case).
      #
      # @return [void]
      def create_controller_file
        # @module_name se usa dentro del template .erb para definir "module Ops"
        @module_name = namespace_name.camelize

        # folder_name define la ruta física: "app/controllers/ops/..."
        folder_name  = namespace_name.underscore

        template "tenant_partitions_controller.rb.erb",
                 "app/controllers/#{folder_name}/tenant_partitions_controller.rb"
      end

      # Inyecta las rutas necesarias en el archivo `config/routes.rb` de la aplicación.
      #
      # Utiliza rutas directas en lugar de `namespace :xyz` para mantener la configuración
      # de rutas lo más limpia y aislada posible, evitando bloques anidados innecesarios.
      #
      # @return [void]
      def add_routes
        folder_name = namespace_name.underscore

        # Definición de rutas explícitas apuntando al controlador generado
        route "post   '#{folder_name}/tenant_partitions', to: '#{folder_name}/tenant_partitions#create'"
        route "delete '#{folder_name}/tenant_partitions/:id', to: '#{folder_name}/tenant_partitions#destroy'"
        route "get    '#{folder_name}/tenant_partitions/:id', to: '#{folder_name}/tenant_partitions#show'"
      end

      # Muestra instrucciones post-generación en la consola.
      #
      # Es vital para advertir al usuario sobre la necesidad de configurar la seguridad (Autenticación),
      # ya que el generador no puede asumir qué sistema de auth usa la aplicación (Devise, JWT, etc).
      #
      # @return [void]
      def show_readme
        # Solo mostramos el README si estamos generando (invoke), no borrando (revoke).
        readme "README" if behavior == :invoke
      end
    end
  end
end
