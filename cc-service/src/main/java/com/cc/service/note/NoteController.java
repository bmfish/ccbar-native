package com.cc.service.note;

import java.net.URI;
import java.util.List;

import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;

import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/notes")
public class NoteController {

    public record NoteRequest(
            @NotBlank @Size(max = 200) String title,
            String content) {
    }

    private final NoteRepository noteRepository;

    public NoteController(NoteRepository noteRepository) {
        this.noteRepository = noteRepository;
    }

    @GetMapping
    public List<Note> list() {
        return noteRepository.findAll();
    }

    @GetMapping("/{id}")
    public Note get(@PathVariable long id) {
        return noteRepository.findById(id).orElseThrow(() -> new NoteNotFoundException(id));
    }

    @PostMapping
    public ResponseEntity<Note> create(@Valid @RequestBody NoteRequest request) {
        Note note = noteRepository.create(request.title(), request.content());
        return ResponseEntity.created(URI.create("/api/notes/" + note.id())).body(note);
    }

    @PutMapping("/{id}")
    public Note update(@PathVariable long id, @Valid @RequestBody NoteRequest request) {
        return noteRepository.update(id, request.title(), request.content())
                .orElseThrow(() -> new NoteNotFoundException(id));
    }

    @DeleteMapping("/{id}")
    public ResponseEntity<Void> delete(@PathVariable long id) {
        if (!noteRepository.delete(id)) {
            throw new NoteNotFoundException(id);
        }
        return ResponseEntity.noContent().build();
    }
}
