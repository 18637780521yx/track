package com.fasttrack.sdk.stability

import java.security.MessageDigest

internal object StackFingerprint {
    fun of(exceptionType: String, stack: String): String {
        val frames = mutableListOf<String>()
        for (line in stack.lineSequence()) {
            val trimmed = line.trim()
            if (trimmed.isEmpty() || trimmed.startsWith("Caused by:")) continue
            frames.add(normalize(trimmed))
            if (frames.size >= 8) break
        }
        val raw = "${exceptionType.ifBlank { "Unknown" }}|${frames.joinToString("|")}"
        return sha256(raw).take(32)
    }

    private fun normalize(line: String): String {
        // Use the MatchResult lambda form of replace — NOT replace(regex, "$N").
        // Java Matcher.appendReplacement treats $ in the replacement as a group
        // reference, so a literal "$N" throws IllegalArgumentException:
        // "Illegal group reference" (e.g. on frames like Foo$1 / Enclosing$2).
        return line
            .replace(Regex("\\$[0-9]+")) { "\$N" }
            .replace(Regex(":\\d+")) { ":N" }
    }

    private fun sha256(input: String): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(input.toByteArray(Charsets.UTF_8))
        return digest.joinToString("") { "%02x".format(it) }
    }
}
