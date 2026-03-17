# TenantPartition 🏢

**TenantPartition** es un framework de infraestructura "Rails-native" diseñado para implementar **Particionamiento Declarativo (List Partitioning)** de PostgreSQL en aplicaciones Ruby on Rails (7.1+).

A diferencia de otras soluciones multi-tenant que dependen de múltiples esquemas (schemas) o hackeos a nivel de consultas (row-level filtering), `tenant_partition` utiliza características nativas del motor de PostgreSQL para dividir físicamente tablas gigantes en tablas más pequeñas y ultrarrápidas por tenant (Cliente, ISP, Organización, etc.). Todo esto, manteniendo intacta la experiencia de desarrollo estándar de ActiveRecord.

## 🚀 Características Principales

* **API Simple y Opt-in:** Activa el particionamiento en tus modelos simplemente agregando la macro `partition_table`.
* **Zero-Downtime Migrations (2 Fases):** Herramientas de nivel empresarial para migrar tablas masivas en producción sin detener el servicio, con barreras anti-errores para despliegues en CI/CD.
* **Introspección Dinámica (Safe Deploys):** El código de tus modelos detecta automáticamente si la tabla en la base de datos ya fue particionada, permitiendo desplegar tu código *antes* de finalizar las migraciones de infraestructura.
* **Smart Hashing para UUIDs:** Evasión automática del límite de 63 caracteres de PostgreSQL en el nombrado de tablas al usar UUIDs largos como claves de partición.
* **Sincronización en Tiempo Real (Live Sync):** Triggers de base de datos automatizados con resolución de conflictos (`UPSERT`) integrada.
* **Backfill Engine con Auto-Aprovisionamiento JIT:** Motor de copiado en segundo plano que crea automáticamente las particiones hijas al vuelo (Just-In-Time) a medida que descubre nuevos tenants.
* **Soporte Nativo CPK:** Totalmente compatible con **Composite Primary Keys** de Rails 7.1+.
* **Gestión de Datos Huérfanos:** Auditoría y auto-reparación de registros que caen en la partición `_default`.

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

**Requisitos mínimos:** Ruby 3.2+, Rails 7.1+ y PostgreSQL 13+ (Optimizado para PG 17). *(Nota: La gema incluye "magia" retrocompatible para operar en Rails 6.0+ bajo su propio riesgo).*

---

## ⚙️ Configuración Inicial

**1. Configuración Global**
Crea un archivo de inicialización para definir tu clave de partición base (por ejemplo, `:isp_id`, `:account_id` o `:tenant_id`).

```ruby
# config/initializers/tenant_partition.rb
TenantPartition.configure do |config|
  # Columna que actuará como discriminador principal en toda la base de datos
  config.partition_key = :isp_id
end
```

**2. Habilitar el DSL en ActiveRecord**
Inyecta el comportamiento base en tu aplicación. Esto **no** particiona tus modelos por defecto, solo les da la habilidad de entender la macro de la gema.

```ruby
# app/models/application_record.rb
class ApplicationRecord < ActiveRecord::Base
  primary_abstract_class

  include TenantPartition::Concerns::Partitioned
end
```

---

## 🛠 Guía 1: Tablas Nuevas (Green Field)

Si estás desarrollando un feature desde cero, particionar una tabla nueva es sumamente directo.

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
  # Activa la Composite Primary Key y los scopes de enrutamiento
  partition_table 
end
```

---

## 🔥 Guía 2: Migrar una Tabla Existente (Zero-Downtime)

Si tienes una tabla legacy con millones de registros y necesitas particionarla en producción sin causar tiempo de inactividad, utiliza nuestra suite de migración en dos fases.

*(⚠️ **Requisito:** La tabla original ya debe tener la columna de tu `partition_key` definida).*

### Fase 1: Preparación, Código y Live Sync (Despliegue 1)
Genera la infraestructura inicial ejecutando:

```bash
rails g tenant_partition:prepare versions isp_id
```

Abre la migración generada en `db/migrate/`. Gracias a la **introspección**, la gema clonará la estructura de tu tabla original y configurará los triggers de PostgreSQL (`INSERT/UPDATE/DELETE`) en un solo paso:

```ruby
def up
  create_partitioned_table_from(
    :versions_partitioned, :versions, partition_key: :isp_id, sync_triggers: true
  )
end
```

**Activa la gema en tu modelo:** Agrega la macro a tu clase ActiveRecord.
```ruby
class Version < ApplicationRecord
  partition_table 
end
```
*(🪄 **Safe Deploy:** Gracias a la Introspección Dinámica, la gema sabe que la base de datos aún no ha finalizado la migración. El modelo seguirá comportándose como una tabla normal sin romper tu aplicación).*

**👉 Ejecuta `rails db:migrate` y despliega a producción.** A partir de este milisegundo, la base de datos enviará todo dato "vivo" nuevo a tu nueva tabla sombra, y tu código estará listo para el futuro.

### Fase 2: Backfill Histórico (Fase Manual)
Con la app corriendo, copia el historial pesado ejecutando esta tarea (idealmente en un entorno de background job o consola de ops):

Para tablas con **IDs Enteros**:
```bash
rake tenant_partition:backfill_data[PaperTrail::Version,versions_partitioned,id]
```
Para tablas con **UUIDs** (Paginación segura por fecha):
```bash
rake tenant_partition:backfill_data[PaperTrail::Version,versions_partitioned,created_at]
```
*(🪄 **Auto-Aprovisionamiento JIT:** El `Migrator` creará las particiones físicas al vuelo utilizando "Smart Hashing" para evitar los límites de 63 caracteres de PostgreSQL. Además, resolverá conflictos usando `ON CONFLICT DO UPDATE` para no pisar los datos vivos).*

### Fase 3: Cutover Atómico (Despliegue 2)
Una vez que el Backfill termine al 100%, genera la migración de intercambio final:

```bash
rails g tenant_partition:cutover versions isp_id
```

**👉 Ejecuta `rails db:migrate` y despliega a producción.** Una transacción atómica cruzará los nombres de las tablas y eliminará los triggers en 1 milisegundo. 
En el instante en que los servidores se reinicien tras el deploy, tu modelo (`Version`) consultará a PostgreSQL, detectará que la tabla ahora sí es particionada, y activará automáticamente sus superpoderes (Composite Primary Keys y Partition Pruning). **¡Cero downtime logrado!**

---

## 🔍 Consultas y Rendimiento (Partition Pruning)

Para que PostgreSQL sea extremadamente rápido, debe aprovechar el **Partition Pruning** (poda de particiones), yendo directamente a la tabla hija en lugar de escanear toda la base de datos.

La gema inyecta automáticamente el scope `for_partition(valor)`.

```ruby
# ❌ LENTO: Escaneará todas las particiones hijas
Conversation.where(status: 'active') 

# ✅ ULTRARRÁPIDO: Va directamente a 'conversations_isp_123'
Conversation.for_partition(123).where(status: 'active')
```

---

## 🏗 Orquestación del Ciclo de Vida de los Tenants

Debes crear la infraestructura física (la tabla hija) para cada Tenant a medida que nacen nuevos clientes en tu sistema.

**Integración directa en tus Modelos:**
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
    TenantPartition.destroy!(self.id)
  end
end
```

**Generador de API:**
Si prefieres orquestar esto desde un microservicio externo, puedes generar un controlador pre-armado:
```bash
rails g tenant_partition:api_controller System
# Creará: app/controllers/system/tenant_partitions_controller.rb
```

---

## 🧹 Mantenimiento: Datos Huérfanos

Si un registro es insertado antes de que su tenant sea aprovisionado, PostgreSQL lo enviará de forma segura a la tabla `_default`. Puedes auditar y corregir esto con tareas Rake:

**1. Auditoría (Encontrar datos perdidos):**
```bash
rake tenant_partition:audit
# [TenantPartition] [AUDIT] Iniciando auditoría...
# [TenantPartition] [ALERTA] Conversation: 450 registros huérfanos encontrados.
```

**2. Limpieza (Mover a su lugar correcto):**
*(Asegúrate de haber aprovisionado el tenant primero)*
```bash
rake tenant_partition:cleanup
# [TenantPartition] [MOVE] -> ID 101: 450 registros recuperados hacia su partición.
```

---

## 📖 Referencia Rápida de la API

**Módulo Global `TenantPartition`**
* `.create!(id)`: Aprovisionamiento de tablas para un tenant en toda la app.
* `.destroy!(id)`: Eliminación de tablas de un tenant (protegido en Prod).
* `.exists?(id)`: Verifica infraestructura.

**Macros de Modelo**
* `partition_table(key: nil)`: Activa particionamiento (opcional: sobreescribe clave).
* `for_partition(value)`: Scope de búsqueda optimizada (con auto-casteo de tipos).
* `create_partition(value)`, `drop_partition(value)`: Operaciones DDL manuales por modelo.
* `partitions`: Devuelve nombres de tablas físicas hijas (incluyendo `_default`).
* `partition_values`: Devuelve los IDs/valores de tenants que ya tienen partición.

**Helpers de Migraciones**
* `create_partitioned_table(table_name, **options)`
* `create_partitioned_table_from(target, source, sync_triggers: false, **options)`
* `swap_partitioned_tables(legacy, partitioned)`

---

## Licencia

Esta gema está disponible como código abierto bajo los términos de la [MIT License](https://opensource.org/licenses/MIT).
