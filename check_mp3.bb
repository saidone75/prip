#!/usr/bin/env bb

;; Author: Marco Marini
;; Description: Check album-by-album that MP3 files correspond to source FLAC files.
;; License: MIT (see LICENSE)
;; SPDX-License-Identifier: MIT

(require '[babashka.fs :as fs] '[clojure.string :as str] '[clojure.set :as set])

(defn fail [message] (throw (ex-info message {})))
(defn usage []
  (println "Usage: check_mp3.bb -f ALBUM_OR_LIBRARY")
  (println "Compare sibling flac/mp3 directories recursively, including uppercase extensions.")
  (println "Match filenames without the extension and optional .cdda suffix; ignore track00 pregaps.")
  (println "Report missing/extra tracks, empty files and ambiguous names. Read-only.")
  (println "This checks file correspondence, not audio equivalence. Exit: 0 = match, 1 = issues."))

(defn inventory [directory format]
  (if-not directory {}
    (reduce
     (fn [tracks path]
       (let [name (str (fs/file-name path))]
         (if-not (str/ends-with? (str/lower-case name) (str "." format)) tracks
           (do
             (when (or (fs/sym-link? path) (not (fs/regular-file? path)))
               (fail (str "Not a regular file: " path)))
             (let [stem (-> name
                            (str/replace #"(?i)\.(flac|mp3)$" "")
                            (str/replace #"(?i)\.cdda$" ""))]
               (if (= "track00" (str/lower-case stem)) tracks
                 (do
                   (when (contains? tracks stem) (fail (str "Ambiguous track name: " path)))
                   (assoc tracks stem path))))))))
     (sorted-map) (sort-by str (fs/list-dir directory)))))

(defn albums [root]
  (reduce
   (fn [result path]
     (let [format (str/lower-case (str (fs/file-name path)))]
       (if (and (#{"flac" "mp3"} format) (fs/directory? path) (not (fs/sym-link? path)))
         (update-in result [(str (fs/parent path)) format] (fnil conj []) path)
         result)))
   (sorted-map)
   (tree-seq #(and (fs/directory? %) (not (fs/sym-link? %)))
             #(sort-by str (fs/list-dir %)) root)))

(defn check-album [album folders]
  (println "[ALBUM]" album)
  (try
    (doseq [[format paths] folders]
      (when (> (count paths) 1) (fail (str "Multiple " format " directories in album"))))
    (let [flacs (inventory (first (get folders "flac")) "flac")
          mp3s (inventory (first (get folders "mp3")) "mp3")
          missing (sort (set/difference (set (keys flacs)) (set (keys mp3s))))
          extra (sort (set/difference (set (keys mp3s)) (set (keys flacs))))
          empty-files (filter #(zero? (fs/size %)) (concat (vals flacs) (vals mp3s)))
          no-flacs (empty? flacs)
          errors (+ (count missing) (count extra) (count empty-files) (if no-flacs 1 0))]
      (println "[INFO]" (count flacs) "FLAC," (count mp3s) "MP3 (excluding pregaps)")
      (when no-flacs (println "[ERROR] No source FLAC tracks"))
      (doseq [stem missing] (println "[MISSING MP3]" (str (get flacs stem))))
      (doseq [stem extra] (println "[EXTRA MP3]" (str (get mp3s stem))))
      (doseq [path empty-files] (println "[EMPTY FILE]" (str path)))
      (when (zero? errors) (println "[OK] All FLAC tracks have matching MP3 files"))
      (flush)
      {:albums 1 :ok (if (zero? errors) 1 0) :missing (count missing)
       :extra (count extra) :empty (count empty-files) :errors errors})
    (catch Exception e
      (println "[ERROR]" (ex-message e))
      {:albums 1 :ok 0 :missing 0 :extra 0 :empty 0 :errors 1})))

(try
  (let [args (vec *command-line-args*)]
    (if (#{["-h"] ["--help"]} args) (usage)
      (do
        (when-not (and (= 2 (count args)) (= "-f" (first args)))
          (fail "Specify -f ALBUM_OR_LIBRARY; use -h for help"))
        (let [root (fs/canonicalize (second args))
              _ (when-not (fs/directory? root) (fail "Not a directory"))
              found (albums root)]
          (when (empty? found) (fail "No flac/mp3 album directories found"))
          (let [totals (reduce (fn [totals [album folders]]
                                 (merge-with + totals (check-album album folders)))
                               {} found)]
            (println (format "[SUMMARY] %d albums: %d OK, %d with issues; %d missing MP3s, %d extra MP3s, %d empty files"
                             (:albums totals) (:ok totals) (- (:albums totals) (:ok totals))
                             (:missing totals) (:extra totals) (:empty totals)))
            (when (pos? (:errors totals)) (System/exit 1)))))))
  (catch Exception e
    (binding [*out* *err*] (println "[ERROR]" (ex-message e)))
    (System/exit 1)))
