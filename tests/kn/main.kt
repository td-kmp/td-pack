import kotlinx.cinterop.ExperimentalForeignApi
import kotlinx.cinterop.toKString
import tdjson.td_create_client_id
import tdjson.td_execute
import tdjson.td_receive
import tdjson.td_send

@OptIn(ExperimentalForeignApi::class)
fun main() {
    td_execute("""{"@type":"setLogVerbosityLevel","new_verbosity_level":1}""")
    val entities = td_execute("""{"@type":"getTextEntities","text":"@telegram /test https://telegram.org"}""")?.toKString()
    check(entities != null && "textEntityTypeUrl" in entities) { "getTextEntities failed: $entities" }
    println(entities)

    val client = td_create_client_id()
    td_send(client, """{"@type":"getOption","name":"version","@extra":42}""")
    repeat(100) {
        val event = td_receive(1.0)?.toKString() ?: return@repeat
        if ("\"@extra\":42" in event) {
            println(event)
            check("optionValueString" in event)
            // Let TDLib shut down before the process exits (see tests/smoke.c).
            td_send(client, """{"@type":"close"}""")
            repeat(30) {
                if (td_receive(1.0)?.toKString()?.contains("authorizationStateClosed") == true) return
            }
            return
        }
    }
    error("no response to getOption")
}
