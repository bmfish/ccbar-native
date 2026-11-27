package com.cc.service.admin;

import java.util.concurrent.ConcurrentHashMap;
import java.util.function.Supplier;

/** 简单的短 TTL 内存缓存，减少管理页重复聚合查询对数据库的压力。 */
public final class TtlCache<K, V> {

    private record Entry<V>(V value, long expiresAt) {
    }

    private final ConcurrentHashMap<K, Entry<V>> entries = new ConcurrentHashMap<>();
    private final long ttlMillis;

    public TtlCache(long ttlMillis) {
        this.ttlMillis = ttlMillis;
    }

    public V get(K key, Supplier<V> loader) {
        long now = System.currentTimeMillis();
        Entry<V> entry = entries.get(key);
        if (entry != null && entry.expiresAt() > now) {
            return entry.value();
        }
        V value = loader.get();
        entries.put(key, new Entry<>(value, System.currentTimeMillis() + ttlMillis));
        return value;
    }

    public void clear() {
        entries.clear();
    }
}
