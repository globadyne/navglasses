package com.tzglasses.hud.core

/**
 * Minimal JSON reader for the bridge's messages, with no Android or library dependency so the
 * core logic can be unit-tested on a plain JVM. Objects become Map<String, Any?>, arrays
 * List<Any?>, numbers Double, plus String, Boolean and null.
 */
object Json {
  fun parse(text: String): Any? {
    val p = Parser(text)
    p.ws()
    val v = p.value()
    p.ws()
    require(p.i == text.length) { "Trailing characters at ${p.i}" }
    return v
  }

  private class Parser(val s: String) {
    var i = 0

    fun ws() {
      while (i < s.length && s[i].isWhitespace()) i++
    }

    fun value(): Any? {
      ws()
      require(i < s.length) { "Unexpected end" }
      return when (val c = s[i]) {
        '{' -> obj()
        '[' -> arr()
        '"' -> str()
        't' -> lit("true", true)
        'f' -> lit("false", false)
        'n' -> lit("null", null)
        else -> if (c == '-' || c.isDigit()) num() else error("Unexpected '$c' at $i")
      }
    }

    private fun lit(word: String, v: Any?): Any? {
      require(s.startsWith(word, i)) { "Bad literal at $i" }
      i += word.length
      return v
    }

    private fun obj(): Map<String, Any?> {
      val m = LinkedHashMap<String, Any?>()
      i++
      ws()
      if (s[i] == '}') { i++; return m }
      while (true) {
        ws()
        val k = str()
        ws()
        require(s[i] == ':') { "Expected ':' at $i" }
        i++
        m[k] = value()
        ws()
        when (s[i]) {
          ',' -> i++
          '}' -> { i++; return m }
          else -> error("Expected ',' or '}' at $i")
        }
      }
    }

    private fun arr(): List<Any?> {
      val a = ArrayList<Any?>()
      i++
      ws()
      if (s[i] == ']') { i++; return a }
      while (true) {
        a.add(value())
        ws()
        when (s[i]) {
          ',' -> i++
          ']' -> { i++; return a }
          else -> error("Expected ',' or ']' at $i")
        }
      }
    }

    private fun str(): String {
      require(s[i] == '"') { "Expected string at $i" }
      i++
      val b = StringBuilder()
      while (true) {
        val c = s[i++]
        when (c) {
          '"' -> return b.toString()
          '\\' -> {
            when (val e = s[i++]) {
              '"', '\\', '/' -> b.append(e)
              'b' -> b.append('\b')
              'f' -> b.append('\u000C')
              'n' -> b.append('\n')
              'r' -> b.append('\r')
              't' -> b.append('\t')
              'u' -> { b.append(s.substring(i, i + 4).toInt(16).toChar()); i += 4 }
              else -> error("Bad escape at $i")
            }
          }
          else -> b.append(c)
        }
      }
    }

    private fun num(): Double {
      val start = i
      if (s[i] == '-') i++
      while (i < s.length && (s[i].isDigit() || s[i] in ".eE+-")) i++
      return s.substring(start, i).toDouble()
    }
  }
}

/** Typed accessors for parsed JSON maps. Wrong types read as null, never crash. */
internal fun Map<String, Any?>.dbl(k: String): Double? = this[k] as? Double
internal fun Map<String, Any?>.str(k: String): String? = this[k] as? String
internal fun Map<String, Any?>.int(k: String): Int? = (this[k] as? Double)?.toInt()
internal fun Map<String, Any?>.long(k: String): Long? = (this[k] as? Double)?.toLong()
@Suppress("UNCHECKED_CAST")
internal fun Map<String, Any?>.obj(k: String): Map<String, Any?>? = this[k] as? Map<String, Any?>
@Suppress("UNCHECKED_CAST")
internal fun Map<String, Any?>.objs(k: String): List<Map<String, Any?>>? =
    (this[k] as? List<*>)?.filterIsInstance<Map<String, Any?>>()
