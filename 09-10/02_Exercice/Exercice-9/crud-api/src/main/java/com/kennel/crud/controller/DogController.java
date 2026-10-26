package com.kennel.crud.controller;

import com.kennel.crud.exception.ResourceNotFoundException;
import com.kennel.crud.model.Dog;
import com.kennel.crud.repository.DogRepository;
import org.springframework.web.bind.annotation.*;

import java.util.List;

@RestController
@RequestMapping("/api/v1/dogs")
public class DogController {

    private final DogRepository dogRepository;

    public DogController(DogRepository dogRepository) {
        this.dogRepository = dogRepository;
    }

    @GetMapping
    public List<Dog> getAllDogs() {
        return dogRepository.findAll();
    }

    @GetMapping("/{dogId}")
    public Dog getDogById(@PathVariable Long dogId) {
        return dogRepository.findById(dogId)
                .orElseThrow(() -> new ResourceNotFoundException("Dog not found with id " + dogId));
    }

    @PostMapping
    public Dog createDog(@RequestBody Dog dog) {
        return dogRepository.save(dog);
    }

    @PutMapping("/{dogId}")
    public Dog updateDog(@PathVariable Long dogId, @RequestBody Dog updatedDog) {
        Dog dog = dogRepository.findById(dogId)
                .orElseThrow(() -> new ResourceNotFoundException("Dog not found with id " + dogId));
        dog.setName(updatedDog.getName());
        dog.setBreed(updatedDog.getBreed());
        dog.setBirthDate(updatedDog.getBirthDate());
        dog.setNeutered(updatedDog.isNeutered());
        return dogRepository.save(dog);
    }

    @DeleteMapping("/{dogId}")
    public void deleteDog(@PathVariable Long dogId) {
        if (!dogRepository.existsById(dogId)) {
            throw new ResourceNotFoundException("Dog not found with id " + dogId);
        }
        dogRepository.deleteById(dogId);
    }
}
