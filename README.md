# TenantPartition

**TenantPartition** es una solución robusta y "Rails-native" para implementar **Particionamiento Declarativo (List Partitioning)** de PostgreSQL en aplicaciones Ruby on Rails.

A diferencia de otras soluciones que dependen de esquemas (schemas) o hackeos a la conexión de base de datos, `tenant_partition` utiliza características nativas de PostgreSQL para dividir tablas gigantes en tablas físicas más pequeñas por tenant (Cliente, ISP, Organización, etc.), manteniendo la experiencia de desarrollo de ActiveRecord estándar.

## 🚀 Características Principales

* **API Simple (Opt-in):** Usa `partition_table` en tus modelos para activar la magia.
* **Migraciones Inteligentes:** Helper `create_partitioned_table` que maneja la complejidad de Postgres automáticamente (Soporte para UUID y BigInt).
* **Zero-Downtime Migrations:** Herramientas completas (Triggers, Backfill background jobs y Generadores) para migrar tablas en producción con millones de registros sin detener el servicio.
* **Soporte Nativo CPK:** Compatible con **Composite Primary Keys** de Rails 7.1+.
* **Gestión de Datos Huérfanos:** Herramientas para auditar y mover datos no asignados desde la tabla `_default`.
* **Safety Guards:** Protección contra operaciones destructivas accidentales en Producción.

---

## 📦 Instalación

Agrega esto a tu `Gemfile`:

```ruby
gem 'tenant_partition'
```

Y ejecuta:

```bash
bundle install
```

---

## ⚙️ Configuración Inicial

### 1. Inicializador
Crea un archivo para definir tu clave de partición global (por ejemplo, `:isp_id`, `:account_id`, `:tenant_id`).

```ruby
# config/initializers/tenant_partition.rb

TenantPartition.configure do |config|
  # Esta es la columna que actuará como discriminador global
  config.partition_key = :isp_id
end
```

### 2. Habilitar en ApplicationRecord
Incluye el concern en tu modelo base. Esto solo habilita el DSL, no particiona nada por defecto.

```ruby
# app/models/application_record.rb
class ApplicationRecord < ActiveRecord::Base
  primary_abstract_class

  include TenantPartition::Concerns::Partitioned
end
```

---

## 🛠 Guía 1: Creando Nuevas Tablas Particionadas

Si vas a crear una tabla desde cero, el proceso es muy directo.

### Paso 1: Migración

Usa el helper `create_partitioned_table` que configurará automáticamente la Primary Key compuesta, la partición LIST y la tabla `_default`.

```ruby
class CreateConversations < ActiveRecord::Migration[7.1]
  def change
    # id_type: :bigint (por defecto) o :uuid
    create_partitioned_table :conversations do |t|
      t.string :subject
      t.text :body
      t.timestamps
      
      # Nota: No definas :id ni la :partition_key explícitamente, la gema lo hace por ti.
    end
  end
end
```

### Paso 2: El Modelo

```ruby
class Conversation < ApplicationRecord
  partition_table 
end
```

### Paso 3: Aprovisionar Tenants

Crea las particiones físicas cuando se registra un nuevo cliente en tu sistema:

```ruby
class Isp < ApplicationRecord
  after_create :provision_infrastructure

  def provision_infrastructure
    # Crea las particiones en todos los modelos registrados
    TenantPartition.create!(self.id)
  end
end
```

---

## 🔥 Guía 2: Migrar una Tabla Existente (Zero-Downtime Migration)

Si tienes una tabla enorme en producción (ej. `versions` de PaperTrail) y quieres particionarla sin tirar la base de datos, `TenantPartition` incluye un generador que automatiza el patrón "Rename, Recreate & Backfill".

**Requisito previo:** La tabla actual *debe* tener la columna de partición (ej. `isp_id`). Si no la tiene, agrégala en una migración estándar antes de continuar.

### Paso 1: Generar la infraestructura de migración

Ejecuta el generador indicando la tabla original y tu partition key:

```bash
rails g tenant_partition:online_migration versions isp_id
```

Esto generará dos archivos de migración y te mostrará las instrucciones.

### Paso 2: Fase de Preparación (Migración 1)

Abre la primera migración generada (`..._prepare_online_migration_for_versions.rb`).
Debes copiar la definición de tus columnas actuales dentro del bloque `create_partitioned_table`.

```ruby
def up
  # 1. Crea la nueva tabla "sombra"
  create_partitioned_table :versions_partitioned, partition_key: :isp_id, id_type: :uuid do |t|
    t.string :item_type, null: false
    t.string :event, null: false
    # ... pega el resto de tus columnas exactas aquí ...
  end

  # 2. Crea los triggers que mantendrán la data sincronizada en tiempo real (Live Sync)
  create_partition_sync_trigger(:versions, :versions_partitioned, :isp_id)
end
```
Ejecuta: `rails db:migrate`. Desde este momento, todos los datos nuevos (INSERT/UPDATE/DELETE) se replican automáticamente a la nueva tabla.

### Paso 3: El Backfill de Datos Históricos

Con tu aplicación corriendo normalmente, usa la Rake Task para copiar los millones de registros antiguos hacia la tabla particionada de forma silenciosa y por lotes.

Si tus IDs son **Enteros Autoincrementables**:
```bash
rake tenant_partition:backfill_data[PaperTrail::Version,versions_partitioned]
```

Si tus IDs son **UUIDs** (Debes decirle que pagine por `created_at`):
```bash
rake tenant_partition:backfill_data[PaperTrail::Version,versions_partitioned,created_at]
```

*(La gema maneja automáticamente los conflictos mediante `UPSERT`, asegurando que el backfill nunca sobrescriba un registro que el Trigger ya haya actualizado en vivo).*

### Paso 4: El Cutover Atómico (Migración 2)

Cuando el backfill finalice y ambas tablas pesen lo mismo, ejecuta la segunda migración (`..._complete_online_migration_for_versions.rb`):

```bash
rails db:migrate
```
Esta migración usa `swap_partitioned_tables` para, en una transacción de milisegundos, borrar los triggers, renombrar tu tabla vieja a `versions_legacy` y la tabla particionada a `versions`. **¡Migración completada con cero downtime!**

---

## 🧹 Mantenimiento (Datos Huérfanos)

Si insertas un registro cuyo tenant no tiene una tabla hija creada, PostgreSQL lo guardará en la tabla `_default`. La gema incluye utilidades para auditar y limpiar esto.

**Auditar:**
```bash
rake tenant_partition:audit
# [ALERTA] Conversation: 450 registros huérfanos encontrados.
```

**Limpiar:** Crea las particiones faltantes y mueve los datos automáticamente a su lugar correcto.
```bash
rake tenant_partition:cleanup
# [FIX] Conversation: Procesando 2 tenants...
# [MOVE] -> ID 101: 450 registros recuperados.
```

---

## 📖 Referencia de API Rápida

### `TenantPartition` (Módulo Global)
* `configure { ... }`
* `create!(tenant_id)`: Crea la infraestructura física para el tenant en todos los modelos.
* `destroy!(tenant_id)`: Borra (DROP) las tablas de ese tenant.
* `exists?(tenant_id)`: Retorna boolean.

### Macro en Modelos (`partition_table`)
* `Conversation.create_partition(123)`
* `Conversation.drop_partition(123)`
* `Conversation.partition_table_exists?(123)`

### Helpers de Migraciones
* `create_partitioned_table(name, partition_key: :id, id_type: :bigint, &block)`
* `create_partition_sync_trigger(source, target, key)`
* `remove_partition_sync_trigger(source, target)`
* `swap_partitioned_tables(legacy_name, partitioned_name)`

---

## Licencia

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
