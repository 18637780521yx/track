package com.fasttrack.sdk.db

import androidx.room.Dao
import androidx.room.Database
import androidx.room.Entity
import androidx.room.Insert
import androidx.room.PrimaryKey
import androidx.room.Query
import androidx.room.RoomDatabase

@Entity(tableName = "track_events")
data class TrackEventEntity(
    @PrimaryKey val eventId: String,
    val name: String,
    val propertiesJson: String,
    val commonPropertiesJson: String,
    val distinctId: String?,
    val anonymousId: String,
    val sessionId: String,
    val timestampMs: Long,
)

@Dao
interface TrackEventDao {
    @Insert
    suspend fun insert(event: TrackEventEntity)

    @Query("SELECT COUNT(*) FROM track_events")
    suspend fun count(): Int

    @Query("SELECT * FROM track_events ORDER BY timestampMs ASC LIMIT :limit")
    suspend fun loadOldest(limit: Int): List<TrackEventEntity>

    @Query("DELETE FROM track_events WHERE eventId IN (:ids)")
    suspend fun deleteByIds(ids: List<String>)

    @Query(
        """
        DELETE FROM track_events WHERE eventId IN (
            SELECT eventId FROM track_events ORDER BY timestampMs ASC LIMIT :n
        )
        """
    )
    suspend fun deleteOldest(n: Int)
}

@Database(entities = [TrackEventEntity::class], version = 1, exportSchema = false)
abstract class TrackDatabase : RoomDatabase() {
    abstract fun eventDao(): TrackEventDao
}
