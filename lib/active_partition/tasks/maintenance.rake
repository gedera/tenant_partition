# frozen_string_literal: true

namespace :active_partition do
  desc "Audita todas las tablas DEFAULT definidas en ActivePartition en busca de registros huérfanos"
  task audit: :environment do
    # Buscamos todas las clases que heredan de ActivePartition::Base cargadas en la app
    resources = ObjectSpace.each_object(Class).select { |klass| klass < ActivePartition::Base }

    puts "\n[ActivePartition] Iniciando auditoría de tablas DEFAULT..."
    puts "-" * 60

    resources.each do |resource|
      begin
        sql = "SELECT count(*) FROM #{resource.default_table}"
        count = ActiveRecord::Base.connection.execute(sql).first['count'].to_i

        if count > 0
          puts "  [ALERTA] #{resource.name}: #{count} registros encontrados en #{resource.default_table}"
        else
          puts "  [OK]     #{resource.name}: Tabla default vacía"
        end
      rescue ActiveRecord::StatementInvalid
        puts "  [ERROR]  #{resource.name}: No se pudo acceder a la tabla #{resource.default_table}"
      end
    end
    puts "-" * 60
  end

  desc "Limpia registros huérfanos moviéndolos de la tabla DEFAULT a su partición correspondiente"
  task cleanup: :environment do
    resources = ObjectSpace.each_object(Class).select { |klass| klass < ActivePartition::Base }
    key = ActivePartition.configuration.partition_key

    puts "\n[ActivePartition] Iniciando proceso de limpieza global..."

    resources.each do |resource|
      puts "\n> Analizando recurso: #{resource.name}"

      # Obtenemos los IDs únicos que tienen datos en la tabla default
      begin
        distict_ids_sql = "SELECT DISTINCT #{key} FROM #{resource.default_table} WHERE #{key} IS NOT NULL"
        ids = ActiveRecord::Base.connection.execute(distict_ids_sql).map { |r| r[key.to_s] }

        if ids.empty?
          puts "  - Sin datos huérfanos."
          next
        end

        ids.each do |id|
          print "  - Procesando ID #{id}: "
          partition = resource.find(id)

          if partition
            moved = partition.populate_from_default
            puts "EXITO (#{moved} registros movidos)"
          else
            puts "ERROR (La partición física no existe)"
          end
        end
      rescue ActiveRecord::StatementInvalid => e
        puts "  - Error al acceder a la tabla: #{e.message}"
      end
    end
    puts "\n[ActivePartition] Limpieza finalizada.\n"
  end
end
