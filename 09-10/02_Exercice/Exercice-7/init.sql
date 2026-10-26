CREATE DATABASE IF NOT EXISTS kennelDB;
USE kennelDB;

CREATE TABLE clients (
  id INT AUTO_INCREMENT PRIMARY KEY,
  nom VARCHAR(100) NOT NULL,
  prenom VARCHAR(100) NOT NULL,
  date_naissance DATE NOT NULL,
  pseudonyme VARCHAR(100) NOT NULL
);

CREATE TABLE adresses (
  id INT AUTO_INCREMENT PRIMARY KEY,
  numero VARCHAR(10) NOT NULL,
  rue VARCHAR(150) NOT NULL,
  code_postal VARCHAR(10) NOT NULL,
  commune VARCHAR(100) NOT NULL
);

CREATE TABLE clients_adresses (
  client_id INT NOT NULL,
  adresse_id INT NOT NULL,
  PRIMARY KEY (client_id, adresse_id),
  FOREIGN KEY (client_id) REFERENCES clients(id) ON DELETE CASCADE,
  FOREIGN KEY (adresse_id) REFERENCES adresses(id) ON DELETE CASCADE
);

CREATE TABLE chiens (
  id INT AUTO_INCREMENT PRIMARY KEY,
  nom VARCHAR(100) NOT NULL,
  date_naissance DATE NOT NULL,
  race VARCHAR(100) NOT NULL,
  sterilise BOOLEAN NOT NULL DEFAULT FALSE,
  client_id INT,
  FOREIGN KEY (client_id) REFERENCES clients(id) ON DELETE SET NULL
);

CREATE TABLE chats (
  id INT AUTO_INCREMENT PRIMARY KEY,
  nom VARCHAR(100) NOT NULL,
  date_naissance DATE NOT NULL,
  race VARCHAR(100) NOT NULL,
  sterilise BOOLEAN NOT NULL DEFAULT FALSE,
  client_id INT,
  FOREIGN KEY (client_id) REFERENCES clients(id) ON DELETE SET NULL
);

INSERT INTO clients (nom, prenom, date_naissance, pseudonyme) VALUES
  ('Durand', 'Alice', '1990-04-12', 'alidu'),
  ('Bernard', 'Hugo', '1985-11-02', 'hugobe');

INSERT INTO adresses (numero, rue, code_postal, commune) VALUES
  ('12', 'Rue des Lilas', '69000', 'Lyon'),
  ('5', 'Avenue de la Gare', '75010', 'Paris');

INSERT INTO clients_adresses (client_id, adresse_id) VALUES
  (1, 1),
  (2, 2);

INSERT INTO chiens (nom, date_naissance, race, sterilise, client_id) VALUES
  ('Rex', '2019-03-01', 'Labrador', TRUE, 1),
  ('Milo', '2021-07-15', 'Beagle', FALSE, 2);

INSERT INTO chats (nom, date_naissance, race, sterilise, client_id) VALUES
  ('Felix', '2020-01-20', 'Europeen', TRUE, 1),
  ('Luna', '2022-05-09', 'Siamois', FALSE, 2);
