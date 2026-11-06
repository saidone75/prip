#!/usr/bin/env bb

;; Author: Marco Marini
;; Description: Sync FLAC or MP3 files to album directories without changing the source.
;; License: MIT (see LICENSE)
;; SPDX-License-Identifier: MIT

(require '[babashka.fs :as fs]
         '[clojure.java.shell :as shell]
         '[clojure.string :as str])

(defn fail [message] (throw (ex-info message {})))
(defn usage []
  (println "Usage: msync.bb -s SOURCE -d DESTINATION -t flac|mp3 [-n] [--force]")
  (println "Sync local format directories to album directories, preserving artist/album paths.")
  (println "Source files and extra destination files are retained. Files with matching size")
  (println "and modification time are skipped unless --force is passed. -n previews changes.")
  (println "Long options: --source, --destination, --format, --dry-run, --force, --help.")
  (println "Requires Babashka and rsync with --mkpath support (3.2.3 or later)."))

(defn options [arguments]
  (loop [remaining arguments result {}]
    (if-let [arg (first remaining)]
      (cond
        (#{"-h" "--help"} arg) (assoc result :help true)
        (#{"-n" "--dry-run"} arg) (recur (next remaining) (assoc result :dry-run true))
        (= "--force" arg) (recur (next remaining) (assoc result :force true))
        (#{"-s" "--source" "-d" "--destination" "-t" "--format"} arg)
        (let [value (second remaining)
              key ({"-s" :source "--source" :source "-d" :destination
                    "--destination" :destination "-t" :format "--format" :format} arg)]
          (when (or (nil? value) (str/starts-with? value "--"))
            (fail (str "Missing value for " arg)))
          (recur (nnext remaining) (assoc result key value)))
        :else (fail (str "Unknown argument: " arg)))
      result)))

(defn parents [path] (take-while some? (iterate fs/parent path)))
(defn check-directory [path]
  (doseq [component (parents path)]
    (when (fs/sym-link? component)
      (fail (str "Destination directory is a symlink: " component)))
    (when (and (fs/exists? component) (not (fs/directory? component)))
      (fail (str "Destination directory is a file: " component)))))

(defn plan [source destination format]
  (let [tree (tree-seq #(and (fs/directory? %) (not (fs/sym-link? %)))
                       #(sort-by str (fs/list-dir %)) source)]
    (reduce
     (fn [albums folder]
       (if (and (fs/directory? folder) (not (fs/sym-link? folder))
                (= format (str/lower-case (str (fs/file-name folder)))))
         (let [tracks (->> (fs/list-dir folder)
                           (filter #(and (fs/regular-file? %) (not (fs/sym-link? %))
                                         (str/ends-with? (str/lower-case (str (fs/file-name %)))
                                                         (str "." format))))
                           (map #(str (fs/file-name %))) sort vec)
               relative (if (= source folder) "" (str (fs/relativize source (fs/parent folder))))
               output (fs/path destination relative)]
           (if (empty? tracks) albums
               (do
                 (when (contains? albums relative)
                   (fail (str "Multiple format directories map to album: " relative)))
                 (check-directory output)
                 (doseq [name tracks :let [target (fs/path output name)]]
                   (when (or (fs/sym-link? target)
                             (and (fs/exists? target) (not (fs/regular-file? target))))
                     (fail (str "Destination track is not a regular file: " target))))
                 (assoc albums relative {:folder folder :tracks tracks :output output}))))
         albums))
     (sorted-map) tree)))

(defn sync-music [{:keys [source destination format dry-run force]}]
  (when-not (and source destination (#{"flac" "mp3"} format))
    (fail "Specify -s SOURCE -d DESTINATION -t flac|mp3."))
  (when-not (fs/which "rsync") (fail "Required command not found: rsync"))
  (when-not (fs/directory? source) (fail (str "Not a source directory: " source)))
  (let [source (fs/canonicalize source)
        destination (fs/normalize (fs/absolutize destination))]
    (check-directory destination)
    (let [destination (fs/canonicalize destination)]
      (when (or (fs/starts-with? destination source) (fs/starts-with? source destination))
        (fail "Source and destination directories must not overlap."))
      (let [albums (plan source destination format)]
        (when (empty? albums) (fail (str "No " format " tracks found in format directories.")))
        (println "[INFO]" (count albums) "albums," (reduce + (map #(count (:tracks %)) (vals albums)))
                 (str/upper-case format) "files" (if dry-run "(dry run)" ""))
        (doseq [[_ {:keys [folder tracks output]}] albums]
          (println "[INFO]" (str folder) "->" (str output))
          (flush)
          (let [command (cond-> ["rsync" "--times" "--omit-dir-times" "--itemize-changes"
                                 "--human-readable" "--mkpath" "--from0" "--files-from=-"]
                          dry-run (conj "--dry-run")
                          force (conj "--ignore-times"))
                {:keys [exit out err]} (apply shell/sh
                                              (concat command ["--" (str folder "/") (str output "/")
                                                               :in (str (str/join "\u0000" tracks) "\u0000")]))]
            (print out) (flush)
            (when (seq err) (binding [*out* *err*] (print err)))
            (when-not (zero? exit) (fail (str "rsync failed with exit status " exit " for " folder)))))
        (println (if dry-run "[INFO] Preview complete." "[INFO] Sync complete."))))))

(try
  (let [opts (options *command-line-args*)]
    (if (:help opts) (usage) (sync-music opts)))
  (catch Exception error
    (binding [*out* *err*] (println "[ERROR]" (.getMessage error)))
    (System/exit 1)))
