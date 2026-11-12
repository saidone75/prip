#!/usr/bin/env bb

;; Author: Marco Marini
;; Description: Sync FLAC or MP3 files to album directories without changing the source.
;; License: MIT (see LICENSE)
;; SPDX-License-Identifier: MIT

(require '[babashka.fs :as fs]
         '[clojure.java.shell :as shell]
         '[clojure.string :as str])

(defn fail [message] (throw (ex-info message {})))
(def default-selection (fs/path (fs/parent (fs/canonicalize *file*)) "msync.albums"))
(defn usage []
  (println "Usage: msync.bb -s SOURCE -d DESTINATION -t flac|mp3 [-n] [--force]")
  (println "                [--albums FILE] [--delete]")
  (println "Sync local format directories to album directories, preserving artist/album paths.")
  (println "Source files are retained; extra destination files are retained unless --delete is passed.")
  (println "Files with matching size are skipped unless --force is passed. -n previews changes.")
  (println "Transfers update destination files in place; interruptions may leave partial files.")
  (println "--albums FILE: exact album names or relative album paths, one per line.")
  (println "Default selection: msync.albums beside this script (required).")
  (println "# Album excludes it; Album enables it. Blank lines and ## instructions are ignored.")
  (println "Albums not listed are excluded. An exclusion wins over a duplicate enabled entry.")
  (println "--delete: after successful copies, delete destination files of the selected format")
  (println "that are absent from the source or not enabled in the album list, then remove their empty parent directories.")
  (println "Long options: --source, --destination, --format, --dry-run, --force, --albums, --delete, --help.")
  (println "Requires Babashka and rsync with --mkpath support (3.2.3 or later)."))

(defn options [arguments]
  (loop [remaining arguments result {}]
    (if-let [arg (first remaining)]
      (cond
        (#{"-h" "--help"} arg) (assoc result :help true)
        (#{"-n" "--dry-run"} arg) (recur (next remaining) (assoc result :dry-run true))
        (= "--force" arg) (recur (next remaining) (assoc result :force true))
        (= "--delete" arg) (recur (next remaining) (assoc result :delete true))
        (#{"-s" "--source" "-d" "--destination" "-t" "--format" "--albums"} arg)
        (let [value (second remaining)
              key ({"-s" :source "--source" :source "-d" :destination
                    "--destination" :destination "-t" :format "--format" :format
                    "--albums" :selection} arg)]
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

(defn read-selection [file]
  (reduce
   (fn [result line]
     (let [line (str/trim line)]
       (if (or (str/blank? line) (str/starts-with? line "##")) result
         (let [excluded (str/starts-with? line "#")
               entry (str/trim (if excluded (subs line 1) line))]
           (when (or (str/blank? entry) (str/starts-with? entry "/")
                     (some #{"." ".."} (str/split entry #"/")))
             (fail (str "Invalid album selection entry: " entry)))
           (update result (if excluded :excluded :included) conj
                   (str/replace entry #"/+$" ""))))))
   {:included #{} :excluded #{}} (str/split-lines (slurp (str file)))))

(defn selected-album? [source folder selection]
  (let [album (fs/parent folder)
        relative (if (= source folder) "" (str (fs/relativize source album)))
        keys [relative (str (fs/file-name album))]]
    (and (some (:included selection) keys)
         (not-any? (:excluded selection) keys))))

(defn music-tree [root]
  (tree-seq #(and (fs/directory? %) (not (fs/sym-link? %)))
            #(sort-by str (fs/list-dir %)) root))

(defn plan [source destination format selection]
  (let [tree (music-tree source)]
    (reduce
     (fn [albums folder]
       (if (and (fs/directory? folder) (not (fs/sym-link? folder))
                (selected-album? source folder selection)
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

(defn deletion-plan [destination format albums]
  (let [expected (into #{} (for [[_ {:keys [tracks output]}] albums name tracks]
                            (str (fs/path output name))))]
    (if-not (fs/exists? destination) []
      (->> (music-tree destination)
           (filter #(and (fs/regular-file? %) (not (fs/sym-link? %))
                         (str/ends-with? (str/lower-case (str (fs/file-name %))) (str "." format))
                         (not (contains? expected (str %)))))
           (sort-by str) vec))))

(defn remove-stale! [destination stale dry-run]
  (doseq [path stale]
    (println (if dry-run "[WOULD DELETE]" "[DELETE]") (str path))
    (when-not dry-run
      (check-directory (fs/parent path))
      (when (or (fs/sym-link? path) (not (fs/regular-file? path)))
        (fail (str "Deletion target changed: " path)))
      (fs/delete path)
      (loop [directory (fs/parent path)]
        (when (and (not= destination directory) (fs/directory? directory)
                   (not (fs/sym-link? directory)) (empty? (fs/list-dir directory)))
          (println "[DELETE EMPTY DIRECTORY]" (str directory))
          (fs/delete directory)
          (recur (fs/parent directory)))))))

(defn sync-music [{:keys [source destination format dry-run force selection delete]}]
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
      (let [selection-file (or selection default-selection)
            selection (read-selection selection-file)
            albums (plan source destination format selection)
            stale (when delete (deletion-plan destination format albums))]
        (println "[INFO] Album selection:" (str selection-file) "-"
                 (count (:included selection)) "enabled," (count (:excluded selection)) "excluded entries.")
        (when delete (println "[INFO]" (count stale) "obsolete destination files selected for deletion."))
        (println "[INFO]" (count albums) "albums," (reduce + (map #(count (:tracks %)) (vals albums)))
                 (str/upper-case format) "files" (if dry-run "(dry run)" ""))
        (doseq [[_ {:keys [folder tracks output]}] albums]
          (println "[INFO]" (str folder) "->" (str output))
          (flush)
          (let [command (cond-> ["rsync" "--inplace" "--size-only"
                                 "--times" "--omit-dir-times" "--itemize-changes"
                                 "--human-readable" "--mkpath" "--from0" "--files-from=-"]
                          dry-run (conj "--dry-run")
                          force (->> (remove #{"--size-only"}) vec)
                          force (conj "--ignore-times"))
                {:keys [exit out err]} (apply shell/sh
                                              (concat command ["--" (str folder "/") (str output "/")
                                                               :in (str (str/join "\u0000" tracks) "\u0000")]))]
            (print out) (flush)
            (when (seq err) (binding [*out* *err*] (print err)))
            (when-not (zero? exit) (fail (str "rsync failed with exit status " exit " for " folder)))))
        ;; Never delete anything if any source scan or transfer failed.
        (when delete (remove-stale! destination stale dry-run))
        (println (if dry-run "[INFO] Preview complete." "[INFO] Sync complete."))))))

(try
  (let [opts (options *command-line-args*)]
    (if (:help opts) (usage) (sync-music opts)))
  (catch Exception error
    (binding [*out* *err*] (println "[ERROR]" (.getMessage error)))
    (System/exit 1)))
