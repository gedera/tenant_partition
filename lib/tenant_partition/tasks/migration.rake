# frozen_string_literal: true

namespace :tenant_partition do
  desc "Copia datos masivos de tabla legacy a particionada (Online Migration)"
  task :backfill_data, [:model_name, :target_table, :order_by] => :environment do |_, args|
    unless args.model_name && args.target_table
      puts "Uso: rake tenant_partition:backfill_data[ModelName,target_table_name,order_column]"
      puts "Ejemplo (IDs Enteros): rake tenant_partition:backfill_data[Conversation,conversations_partitioned]"
      puts "Ejemplo (UUIDs):       rake tenant_partition:backfill_data[PaperTrail::Version,versions_partitioned,created_at]"
      exit 1
    end

    model = args.model_name.constantize
    target = args.target_table
    order = (args.order_by || :id).to_sym

    migrator = TenantPartition::Migrator.new(model: model, target_table: target)
    migrator.copy_data!(order_by: order)
  end
end
