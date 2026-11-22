package com.cc.service.note;

import java.time.OffsetDateTime;
import java.util.List;
import java.util.Optional;

import org.springframework.jdbc.core.RowMapper;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Repository;

@Repository
public class NoteRepository {

    private static final String COLUMNS = "id, title, content, created_at, updated_at";

    private static final RowMapper<Note> ROW_MAPPER = (rs, rowNum) -> new Note(
            rs.getLong("id"),
            rs.getString("title"),
            rs.getString("content"),
            rs.getObject("created_at", OffsetDateTime.class),
            rs.getObject("updated_at", OffsetDateTime.class));

    private final JdbcClient jdbcClient;

    public NoteRepository(JdbcClient jdbcClient) {
        this.jdbcClient = jdbcClient;
    }

    public List<Note> findAll() {
        return jdbcClient.sql("select " + COLUMNS + " from note order by id desc")
                .query(ROW_MAPPER)
                .list();
    }

    public Optional<Note> findById(long id) {
        return jdbcClient.sql("select " + COLUMNS + " from note where id = :id")
                .param("id", id)
                .query(ROW_MAPPER)
                .optional();
    }

    public Note create(String title, String content) {
        return jdbcClient.sql("insert into note (title, content) values (:title, :content) returning " + COLUMNS)
                .param("title", title)
                .param("content", content)
                .query(ROW_MAPPER)
                .single();
    }

    public Optional<Note> update(long id, String title, String content) {
        return jdbcClient.sql("update note set title = :title, content = :content, updated_at = now() where id = :id returning " + COLUMNS)
                .param("title", title)
                .param("content", content)
                .param("id", id)
                .query(ROW_MAPPER)
                .optional();
    }

    public boolean delete(long id) {
        return jdbcClient.sql("delete from note where id = :id")
                .param("id", id)
                .update() > 0;
    }
}
