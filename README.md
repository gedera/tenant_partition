# TenantPartition 🏢

**TenantPartition** es un framework de infraestructura "Rails-native" diseñado para implementar **Particionamiento Declarativo (List Partitioning)** de PostgreSQL en aplicaciones Ruby on Rails (7.1+).

A diferencia de otras soluciones multi-tenant que dependen de múltiples esquemas (schemas) o hackeos a nivel de consultas (row-level filtering), `tenant_partition` utiliza características nativas del motor de PostgreSQL para dividir físicamente tablas gigantes en tablas más pequeñas y ultrarrápidas por tenant (Cliente, ISP, Organización, etc.). Todo esto, manteniendo intacta la experiencia de desarrollo estándar de ActiveRecord.

## 🚀 Características Principales

* **API Simple y Opt-in:** Activa el particionamiento en tus modelos simplemente agregando la macro `partition_table`.
* **Zero-Downtime Migrations:** Herramientas de nivel empresarial para migrar tablas masivas en producción sin detener el servicio.
* **Introspección de Esquemas:** Clonación dinámica de tablas legacy (`create_partitioned_table_from`) sin necesidad de escribir las columnas a mano.
* **Sincronización en Tiempo Real (Live Sync):** Triggers de base de datos automatizados con resolución de conflictos (`UPSERT`) integrada.
* **Backfill Engine con Auto-Aprovisionamiento JIT:** Motor de copiado en segundo plano que crea automáticamente las particiones hijas al vuelo (Just-In-Time) a medida que descubre nuevos tenants en el historial.
* **Soporte Nativo CPK:** Totalmente compatible con **Composite Primary Keys** de Rails 7.1+.
* **Gestión de Datos Huérfanos:** Auditoría y auto-reparación de registros que caen en la partición `_default`.
* **Safety Guards:** Protección estricta contra operaciones destructivas accidentales en entornos de Producción.

---

## 📦 Instalación

Agrega la gema a tu `Gemfile`:

```ruby
gem 'tenant_partition'
```

Y ejecuta:

```bash
bundle install
```

Requisitos mínimos: **Ruby 3.2+**, **Rails 7.1+** y **PostgreSQL 13+** (Optimizado para PG 17).

---

## ⚙️ Configuración Inicial

Crea un archivo de inicialización para definir tu clave de partición global (por ejemplo, `:isp_id`, `:account_id` o `:tenant_id`).

```ruby
# config/initializers/tenant_partition.rb
TenantPartition.configure do |config|
  # Columna que actuará como discriminador principal en toda la base de datos
  config.partition_key = :isp_id
end
```

Habilita el DSL de la gema en tu modelo base de ActiveRecord:

```ruby
# app/models/application_record.rb
class ApplicationRecord < ActiveRecord::Base
  primary_abstract_class

  # Esto solo inyecta el DSL, no particiona ningún modelo por defecto.
  include TenantPartition::Concerns::Partitioned
end
```

---

## 🛠 Guía 1: Creando Nuevas Tablas Particionadas

Si estás desarrollando un feature desde cero, crear una tabla particionada es sumamente sencillo.

### 1. La Migración
Usa el helper `create_partitioned_table`. Este configura automáticamente la Primary Key Compuesta, la partición tipo `LIST` y la tabla `_default`.

```ruby
class CreateConversations < ActiveRecord::Migration[7.1]
  def change
    # Soporta id_type: :bigint (por defecto) o :uuid
    create_partitioned_table :conversations, id_type: :uuid do |t|
      t.string :subject
      t.text :body
      t.timestamps
      
      # 🪄 Nota: NO definas explícitamente el :id ni el :isp_id aquí. 
      # La gema lo hace por ti automáticamente.
    end
  end
end
```

### 2. El Modelo
```ruby
class Conversation < ApplicationRecord
  partition_table 
end
```

---

## 🔥 Guía 2: Migrar una Tabla Existente (Zero-Downtime Migration)

Si tienes una tabla con millones de registros (ej. `versions` de PaperTrail) y necesitas particionarla en producción sin causar tiempo de inactividad, utiliza nuestra suite de migraciones en línea.

*(⚠️ **Requisito:** La tabla original ya debe tener la columna de tu `partition_key` definida, aunque algunos registros la tengan en `null`)*.

### Paso 1: Generar la infraestructura
Ejecuta el generador indicando la tabla a migrar y la clave de partición:

```bash
rails g tenant_partition:online_migration versions isp_id
```
*Esto creará dos archivos de migración estructurados cronológicamente.*

### Paso 2: Fase de Preparación y Live Sync (Migración 1)
Abre la primera migración generada (`..._prepare_online_migration_for_versions.rb`). Tienes dos opciones para definir la nueva tabla particionada:

**Opción A: Clonación Automática (Recomendado)**
Gracias a la **introspección**, la gema puede clonar la estructura de tu tabla original y configurarle los triggers en un solo paso. Ideal si no quieres modificar el esquema.

```ruby
def up
  # 🪄 Magia de TenantPartition: Clona el esquema y sincroniza eventos automáticamente.
  create_partitioned_table_from(
    :versions_partitioned, # Tabla destino (sombra)
    :versions,             # Tabla origen (legacy)
    partition_key: :isp_id,
    sync_triggers: true
    # id_type: :uuid       # Descomentar si tu tabla usa UUIDs
  ) do |t|
    # (Opcional) Agrega nuevos índices a la tabla particionada aquí
  end
end
```

**Opción B: Refactorización Manual (Opcional)**
Si deseas aprovechar esta migración para **limpiar tu esquema** (ej. eliminar columnas deprecadas o cambiar tipos de datos), puedes definir la tabla manualmente y luego aplicar los triggers:

```ruby
def up
  # Defines la estructura limpia que deseas para el futuro
  create_partitioned_table :versions_partitioned, partition_key: :isp_id, id_type: :uuid do |t|
    t.string :item_type, null: false
    t.string :event, null: false
    # Omitimos columnas viejas que ya no usamos...
  end

  # Instalas los triggers de sincronización
  create_partition_sync_trigger(:versions, :versions_partitioned, :isp_id)
end
```

Ejecuta `rails db:migrate`. A partir de este milisegundo, cualquier `INSERT/UPDATE/DELETE` en tu app se replica automáticamente a la tabla particionada (sombra).

### Paso 3: El Backfill de Datos Históricos
Con la app corriendo y los datos nuevos sincronizándose solos, copiamos el historial pesado ejecutando la siguiente tarea Rake (idealmente en un entorno de background job o consola de ops):

Para tablas con **IDs Enteros**:
```bash
rake tenant_partition:backfill_data[PaperTrail::Version,versions_partitioned,id]
```

Para tablas con **UUIDs** (Paginación segura por fecha):
```bash
rake tenant_partition:backfill_data[PaperTrail::Version,versions_partitioned,created_at]
```

*(🪄 **Auto-Aprovisionamiento JIT:** El `Migrator` procesará lotes manejando los conflictos inteligentemente mediante `ON CONFLICT DO UPDATE`. Además, analizará los datos en tiempo real y **creará automáticamente las tablas físicas hijas** a medida que descubra nuevos `isp_id`, garantizando que tu infraestructura se despliegue a la perfección sin intervención manual).*

### Paso 4: El Cutover Atómico (Migración 2)
El "Cutover" es el momento exacto en el que tu aplicación deja de usar la tabla original y comienza a usar la tabla particionada. Para lograr el **cero downtime**, la gema utiliza una transacción atómica de milisegundos.

**1. Verificación previa:** Comprueba que ambas tablas tengan la misma información en consola:
```ruby
PaperTrail::Version.count == PaperTrail::Version.from('versions_partitioned').count
```

**2. Ejecutar el intercambio:**
```bash
rails db:migrate
```
El helper `swap_partitioned_tables` abrirá una transacción para:
1. Eliminar los Triggers de Live Sync.
2. Renombrar la tabla original a `versions_legacy` (backup de seguridad).
3. Renombrar la tabla particionada a `versions`.

**¡Felicidades! Has particionado una tabla masiva sin un solo segundo de downtime.** 🚀
*(Si detectas algún problema en producción tras el Cutover, ejecutar `rails db:rollback` deshará el cambio de nombres y reactivará los triggers instantáneamente de forma segura).*

---

## 🔍 Consultando Datos (Scopes Automáticos)

Para que PostgreSQL sea extremadamente rápido en una arquitectura particionada, debe aprovechar el **Partition Pruning** (poda de particiones). Esto significa que la base de datos debe saber exactamente en qué tabla hija buscar, evitando escanear todas las demás.

Para facilitarte esto, al usar la macro `partition_table` en un modelo, la gema inyecta automáticamente el scope `for_partition(valor)`.

**Ejemplo de uso:**

```ruby
# ❌ Evita hacer consultas sin la clave de partición si es posible:
Conversation.where(status: 'active') # Escaneará todas las particiones buscando activos

# ✅ Forma correcta usando el scope inyectado:
Conversation.for_partition(123).where(status: 'active')

# El scope equivale a escribir:
Conversation.where(isp_id: 123).where(status: 'active')
```

Esto garantiza que el motor de PostgreSQL vaya directamente a la tabla física `conversations_isp_123`, logrando respuestas en milisegundos sin importar cuán grande sea tu sistema global.

---

## 🏗 Orquestación de Tenants

Debes crear la infraestructura física (la tabla hija) para cada Tenant a medida que nacen nuevos clientes en tu sistema.

```ruby
# app/models/isp.rb
class Isp < ApplicationRecord
  after_create :provision_infrastructure
  after_destroy :destroy_infrastructure

  private

  def provision_infrastructure
    # Crea las particiones en TODOS los modelos que tengan `partition_table`
    TenantPartition.create!(self.id)
  end

  def destroy_infrastructure
    # Destruye las particiones y sus datos (Protegido por SafetyGuard en Producción)
    TenantPartition.destroy!(self.id)
  end
end
```

**Comandos manuales por modelo:**
```ruby
Conversation.create_partition(123)        # Crea 'conversations_isp_123'
Conversation.drop_partition(123)          # Elimina 'conversations_isp_123'
Conversation.partition_table_exists?(123) # => true / false
```

---

## 🧹 Mantenimiento: Datos Huérfanos

Si un registro nuevo o vivo entra al sistema antes de que se aprovisione su tabla hija, PostgreSQL lo enviará de forma segura a la tabla `_default`. La gema provee tareas para mantener tu base de datos saludable:

**1. Auditoría (Encontrar datos perdidos):**
```bash
rake tenant_partition:audit
# [TenantPartition] [AUDIT] Iniciando auditoría...
# [TenantPartition] [ALERTA] Conversation: 450 registros huérfanos encontrados.
```

**2. Limpieza (Mover a su lugar correcto):**
*(Asegúrate de haber aprovisionado el tenant primero con `TenantPartition.create!(id)`)*
```bash
rake tenant_partition:cleanup
# [TenantPartition] [FIX] Conversation: Procesando 2 tenants...
# [TenantPartition] [MOVE] -> ID 101: 450 registros recuperados.
```

---

## 📖 Referencia de la API

### Módulo Global `TenantPartition`
* `.configure { |c| ... }`: Inicialización.
* `.create!(id)`: Aprovisionamiento global de un tenant.
* `.destroy!(id)`: Eliminación global de un tenant.
* `.exists?(id)`: Verifica infraestructura global.

### Macros y Scopes de Modelo
* `partition_table(key: nil)`: Activa particionamiento (opcionalmente sobreescribe la clave global).
* `for_partition(value)`: Scope automático para filtrar por la clave de partición (ej. `where(isp_id: value)`).

### Helpers de Migraciones
* `create_partitioned_table(table_name, **options)`
* `create_partitioned_table_from(target, source, sync_triggers: false, **options)`
* `create_partition_sync_trigger(source, target, partition_key)`
* `remove_partition_sync_trigger(source, target)`
* `swap_partitioned_tables(legacy_table, partitioned_table)`

---

## 🛡 Consideraciones de Producción

En entornos productivos (`Rails.env.production?`), la gema activa un `SafetyGuard` que impide ejecutar borrados accidentales de particiones. Si legítimamente necesitas eliminar la infraestructura de un tenant, debes pasar un bypass explícito en las variables de entorno si lo ejecutas vía Rake, o manejar el riesgo explícitamente en tu código.

---

## Licencia

Esta gema está disponible como código abierto bajo los términos de la [MIT License](https://opensource.org/licenses/MIT).
