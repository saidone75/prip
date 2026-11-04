#!/usr/bin/env bb

;; Author: Marco Marini
;; Description: Verify decoded FLAC audio against prip.sh manifests.
;; License: MIT (see LICENSE)
;; SPDX-License-Identifier: MIT

(require '[babashka.fs :as fs]
         '[babashka.process :as process]
         '[clojure.string :as str])

(defn fail [message] (throw (ex-info message {})))

(defn usage []
  (println "Usage: verify.bb -f ALBUM_OR_LIBRARY")
  (println "Recursively check logs/trial-a/audio.sha256 against album/flac files.")
  (println "Supports .cdda renaming.")
  (println "Read-only. Requires flac. Exit: 0 = verified, 1 = errors."))

(defn audio-hash [file]
  ;; Stream decoded samples: memory use does not depend on track length.
  (let [p (process/process ["flac" "--decode" "--stdout" "--force-raw-format"
                            "--endian=little" "--sign=signed" "--" (str file)]
                           {:out :stream :err :inherit})
        digest (java.security.MessageDigest/getInstance "SHA-256")
        buffer (byte-array 65536)]
    (try
      (with-open [input (:out p)]
        (loop []
          (let [n (.read input buffer)]
            (when (pos? n)
              (.update digest buffer 0 n)
              (recur)))))
      (when-not (zero? (:exit @p)) (fail (str "FLAC decoding failed: " file)))
      (apply str (map #(format "%02x" (bit-and 255 %)) (.digest digest)))
      (finally (process/destroy p)))))

(defn track-file [album name]
  (let [stem (str/replace name #"(?i)\.wav$" "")
        names (distinct [(str stem ".flac")
                         (str (str/replace stem #"\.cdda$" "") ".flac")])
        matches (filter fs/regular-file? (map #(fs/path album "flac" %) names))]
    (when (> (count matches) 1) (fail (str "Ambiguous FLAC match: " name)))
    (first matches)))

(defn check-manifest [manifest]
  (println "[INFO]" (str manifest))
  (let [album (-> manifest fs/parent fs/parent fs/parent)
        lines (str/split-lines (slurp (str manifest)))]
    (when (empty? lines) (fail "Empty manifest"))
    (reduce
     (fn [errors [index line]]
       (try
         (let [[_ expected name] (re-matches #"([0-9a-fA-F]{64})  (.+)" line)]
           (when-not (and name (not (str/includes? name "/"))
                          (not (str/includes? name "\\"))
                          (str/ends-with? (str/lower-case name) ".wav"))
             (fail (str "Invalid manifest entry at line " (inc index))))
           (if-let [file (track-file album name)]
             (do
               (when-not (= (str/lower-case expected) (audio-hash file))
                 (fail (str "Checksum mismatch: " file)))
               (println "[OK]" (str file)))
             (if (re-matches #"track00(?:\.cdda)?\.wav" name)
               nil
               (fail (str "Missing FLAC: " name))))
           errors)
         (catch Exception e
           (println "[ERROR]" (ex-message e))
           (inc errors))))
     0 (map-indexed vector lines))))

(try
  (let [args (vec *command-line-args*)]
    (if (#{["-h"] ["--help"]} args)
      (usage)
      (do
        (when-not (and (= 2 (count args)) (= "-f" (first args)))
          (usage) (fail "Specify -f ALBUM_OR_LIBRARY"))
        (when-not (fs/which "flac") (fail "Required command not found: flac"))
        (let [root (fs/absolutize (second args))
              _ (when-not (fs/directory? root) (fail (str "Not a directory: " root)))
              ;; prip.sh compares both reads before publishing; trial-a suffices.
              manifests (->> (fs/glob root "**/audio.sha256")
                             (filter #(and (fs/regular-file? %)
                                           (= "trial-a" (str (fs/file-name (fs/parent %))))
                                           (= "logs" (str (fs/file-name (-> % fs/parent fs/parent))))))
                             (sort-by str))]
          (when (empty? manifests) (fail "No logs/trial-a/audio.sha256 manifests found"))
          (let [errors (reduce + (for [manifest manifests]
                                   (try (check-manifest manifest)
                                        (catch Exception e
                                          (println "[ERROR]" (str manifest) (ex-message e))
                                          1))))]
            (println "[INFO]" (count manifests) "manifests," errors "errors")
            (when (pos? errors) (System/exit 1)))))))
  (catch Exception e
    (binding [*out* *err*] (println "[ERROR]" (ex-message e)))
    (System/exit 1)))
