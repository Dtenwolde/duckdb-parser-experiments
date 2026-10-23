SET current_dialect = 'saneql';
person.filter(age > 25).project(name).orderby(name)
;
SELECT name FROM person WHERE age IN (SELECT age FROM (person.filter(age > 40).project(age)));
